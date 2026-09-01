defmodule HydraSrt.SourceProbe do
  @moduledoc false

  require Logger

  alias HydraSrt.LogSanitizer
  alias HydraSrt.RouteHandler

  @default_ffprobe_timeout_ms 15_000

  @spec probe(map(), keyword()) :: {:ok, map()} | {:error, atom() | binary()}
  def probe(route_params, opts \\ [])

  def probe(route_params, opts) when is_map(route_params) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_ffprobe_timeout_ms)

    with {:ok, probe_uri} <- build_probe_uri(route_params),
         {:ok, ffprobe_path} <- find_ffprobe(),
         {:ok, raw_output} <-
           run_ffprobe(ffprobe_path, probe_uri, timeout_ms, listener_source?(route_params)),
         {:ok, parsed_output} <- decode_output(raw_output) do
      Logger.info("SourceProbe: ffprobe succeeded uri=#{sanitize_uri(probe_uri)}")

      {:ok,
       %{
         "probe_uri" => sanitize_uri(probe_uri),
         "streams" => Map.get(parsed_output, "streams", []),
         "format" => Map.get(parsed_output, "format"),
         "programs" => normalize_programs(Map.get(parsed_output, "programs", [])),
         "raw" => sanitize_output(parsed_output)
       }}
    end
  end

  def probe(_route_params, _opts), do: {:error, :invalid_source}

  @spec client_error(term()) :: String.t()
  def client_error(reason) do
    reason
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "Failed to test source connection"
      message -> String.slice(message, 0, 500)
    end
  end

  # A listener source has nothing to answer with until a sender connects to it,
  # which is why testing an idle backup source always times out. Say so instead
  # of reporting a bare timeout the operator cannot act on.
  @spec listener_timeout_hint(boolean()) :: binary()
  def listener_timeout_hint(true),
    do: ". A listener source can only be tested while a sender is connected to it"

  def listener_timeout_hint(_listener_source?), do: ""

  @spec listener_source?(map()) :: boolean()
  def listener_source?(route_params) when is_map(route_params) do
    mode = Map.get(route_params, "mode") || Map.get(route_params, :mode)
    is_binary(mode) and String.downcase(mode) == "listener"
  end

  def listener_source?(_route_params), do: false

  @spec build_probe_uri(map()) :: {:ok, binary()} | {:error, atom() | binary()}
  def build_probe_uri(route_params) when is_map(route_params) do
    with {:ok, source} <- RouteHandler.source_from_record(route_params) do
      case source["kind"] do
        "srt" ->
          srt = source["srt"] || %{}

          case {srt["uri"], srt["localport"] || srt["port"]} do
            {uri, port}
            when is_binary(uri) and byte_size(uri) > 0 and is_integer(port) and port > 0 ->
              {:ok, uri}

            {_uri, nil} ->
              {:error, "SRT source is missing a valid port"}

            {_uri, port} when not (is_integer(port) and port > 0) ->
              {:error, "SRT source has an invalid port"}

            {_uri, _port} ->
              {:error, "SRT source is missing a valid URI"}
          end

        kind when kind in ["udp", "rtp"] ->
          payload = source[kind] || %{}

          case payload["port"] do
            port when is_integer(port) ->
              address = payload["address"] || "0.0.0.0"
              probe_scheme = if kind == "rtp", do: "rtp", else: "udp"
              uri = "#{probe_scheme}://#{address}:#{port}"
              {:ok, add_multicast_interface(uri, route_params, payload)}

            _ ->
              {:error, "UDP source is missing a valid port"}
          end

        "hls" ->
          hls = source["hls"] || %{}

          case hls["uri"] do
            uri when is_binary(uri) and byte_size(uri) > 0 -> {:ok, uri}
            _ -> {:error, "HLS source is missing a valid URI"}
          end

        other ->
          {:error, "Unsupported source type for probe: #{inspect(other)}"}
      end
    end
  end

  def build_probe_uri(_), do: {:error, :invalid_source}

  defp find_ffprobe do
    case System.find_executable("ffprobe") do
      nil ->
        Logger.error("SourceProbe: ffprobe executable not found in PATH")
        {:error, "ffprobe is not available on the server"}

      _path ->
        Logger.debug("SourceProbe: using ffprobe executable from PATH")
        {:ok, :ffprobe}
    end
  end

  def run_ffprobe(path, probe_uri, timeout_ms, listener_source? \\ false)

  def run_ffprobe(:ffprobe, probe_uri, timeout_ms, listener_source?)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    sanitized_uri = sanitize_uri(probe_uri)

    Logger.info("SourceProbe: starting ffprobe uri=#{sanitized_uri}")

    Logger.debug("SourceProbe: command=ffprobe #{Enum.join(ffprobe_args(sanitized_uri), " ")}")

    case System.find_executable("ffprobe") do
      nil ->
        {:error, "ffprobe is not available on the server"}

      executable ->
        # System.cmd cannot cancel the OS process it spawned, so a probe that
        # timed out used to leave ffprobe running and holding the source port
        # for good. Own the port here so the child can actually be killed.
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:args, ffprobe_args(probe_uri)}
          ])

        deadline = System.monotonic_time(:millisecond) + timeout_ms

        collect_ffprobe_output(port, "", deadline, %{
          timeout_ms: timeout_ms,
          sanitized_uri: sanitized_uri,
          listener_source?: listener_source?
        })
    end
  end

  @doc false
  def collect_ffprobe_output(port, acc, deadline, context) do
    remaining = deadline - System.monotonic_time(:millisecond)

    receive do
      {^port, {:data, chunk}} ->
        collect_ffprobe_output(port, acc <> chunk, deadline, context)

      {^port, {:exit_status, 0}} ->
        Logger.debug("SourceProbe: ffprobe completed successfully uri=#{context.sanitized_uri}")
        {:ok, acc}

      {^port, {:exit_status, exit_status}} ->
        error = normalize_ffprobe_error(acc, exit_status)

        Logger.error(
          "SourceProbe: ffprobe failed uri=#{context.sanitized_uri} error=#{inspect(error)}"
        )

        {:error, error}
    after
      max(remaining, 0) ->
        stop_ffprobe(port)

        Logger.warning(
          "SourceProbe: ffprobe timed out uri=#{context.sanitized_uri} timeout_ms=#{context.timeout_ms}"
        )

        {:error,
         "ffprobe timed out after #{context.timeout_ms}ms#{listener_timeout_hint(context.listener_source?)}"}
    end
  end

  @doc false
  def stop_ffprobe(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
        :ok

      _ ->
        :ok
    end

    close_port(port)
  end

  @doc false
  def close_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp ffprobe_args(probe_uri) do
    [
      "-v",
      "error",
      "-print_format",
      "json",
      "-show_streams",
      "-show_format",
      "-show_programs",
      probe_uri
    ]
  end

  @doc false
  def decode_output(output) do
    case output |> extract_json_payload() |> Jason.decode() do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, reason} ->
        Logger.error(
          "SourceProbe: ffprobe returned invalid JSON error=#{inspect(reason)} output=#{inspect(sanitize_uri(output))}"
        )

        {:error, "ffprobe returned invalid JSON"}
    end
  end

  @doc false
  def extract_json_payload(output) when is_binary(output) do
    case Regex.run(~r/(?:\A|\n)(\{)/s, output, return: :index, capture: :all_but_first) do
      [{index, _length}] -> binary_part(output, index, byte_size(output) - index)
      nil -> output
    end
  end

  @doc false
  @spec normalize_programs(term()) :: [map()]
  def normalize_programs(programs) when is_list(programs) do
    programs
    |> Enum.map(fn program ->
      tags = if is_map(program["tags"]), do: program["tags"], else: %{}
      name = if is_binary(tags["service_name"]), do: tags["service_name"], else: nil

      %{
        "program_number" => program["program_num"],
        "pmt_pid" => program["pmt_pid"],
        "pcr_pid" => program["pcr_pid"],
        "name" => name,
        "streams" => normalize_program_streams(program["streams"])
      }
    end)
    |> Enum.filter(&selectable_program?/1)
  end

  def normalize_programs(_), do: []

  # Program number 0 is reserved for the NIT and is never a service, and ffprobe also
  # reports a bare PAT entry that way when it read the table before the PMT arrived.
  # Neither is something an operator can select, so they must not reach the picker.
  @spec selectable_program?(map()) :: boolean()
  defp selectable_program?(program) do
    case program["program_number"] do
      number when is_integer(number) and number > 0 -> true
      _ -> false
    end
  end

  @spec normalize_program_streams(term()) :: [map()]
  def normalize_program_streams(streams) when is_list(streams) do
    Enum.map(streams, fn stream ->
      %{"codec_type" => stream["codec_type"], "codec_name" => stream["codec_name"]}
    end)
  end

  def normalize_program_streams(_), do: []

  @spec add_multicast_interface(binary(), map(), map()) :: binary()
  def add_multicast_interface(uri, route_params, payload)
      when is_binary(uri) and is_map(route_params) and is_map(payload) do
    interface = route_params["interface_sys_name"] || route_params[:interface_sys_name]

    if is_binary(interface) and interface != "" and is_binary(payload["multicast_iface"]) do
      local_address =
        case RouteHandler.resolve_interface_bind_ip(interface) do
          {:ok, address} -> address
          _ -> route_params["localaddress"] || route_params[:localaddress]
        end

      if is_binary(local_address) and local_address != "" do
        uri <> "?" <> URI.encode_query(%{"localaddr" => local_address})
      else
        uri
      end
    else
      uri
    end
  end

  defp normalize_ffprobe_error(output, exit_status) do
    message =
      output
      |> strip_json_payload()
      |> String.trim()
      |> case do
        "" -> "ffprobe failed with exit status #{exit_status}"
        trimmed -> trimmed
      end

    sanitize_uri(message)
  end

  # ffprobe still prints its json skeleton when it fails, so the payload has to
  # come off before what is left can be used as a message. Without this the
  # operator is shown a bare "{ }".
  defp strip_json_payload(output) when is_binary(output) do
    case Regex.run(~r/(?:\A|\n)(\{)/s, output, return: :index, capture: :all_but_first) do
      [{index, _length}] -> binary_part(output, 0, index)
      nil -> output
    end
  end

  defp sanitize_output(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested_value} -> {key, sanitize_output(nested_value)} end)
    |> Map.new()
  end

  defp sanitize_output(value) when is_list(value), do: Enum.map(value, &sanitize_output/1)
  defp sanitize_output(value) when is_binary(value), do: sanitize_uri(value)
  defp sanitize_output(value), do: value

  defp sanitize_uri(value) when is_binary(value) do
    LogSanitizer.sanitize_payload(value)
  end

  defp sanitize_uri(value), do: value
end

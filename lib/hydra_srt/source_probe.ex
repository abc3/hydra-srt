defmodule HydraSrt.SourceProbe do
  @moduledoc false

  require Logger

  alias HydraSrt.RouteHandler

  @default_ffprobe_timeout_ms 15_000
  @passphrase_mask "[REDACTED]"

  @spec probe(map(), keyword()) :: {:ok, map()} | {:error, atom() | binary()}
  def probe(route_params, opts \\ [])

  def probe(route_params, opts) when is_map(route_params) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_ffprobe_timeout_ms)

    with {:ok, probe_uri} <- build_probe_uri(route_params),
         {:ok, ffprobe_path} <- find_ffprobe(),
         {:ok, raw_output} <- run_ffprobe(ffprobe_path, probe_uri, timeout_ms),
         {:ok, parsed_output} <- decode_output(raw_output) do
      Logger.info("SourceProbe: ffprobe succeeded uri=#{sanitize_uri(probe_uri)}")

      {:ok,
       %{
         "probe_uri" => sanitize_uri(probe_uri),
         "streams" => Map.get(parsed_output, "streams", []),
         "format" => Map.get(parsed_output, "format"),
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
              {:ok, "#{probe_scheme}://#{address}:#{port}"}

            _ ->
              {:error, "UDP source is missing a valid port"}
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

  def run_ffprobe(:ffprobe, probe_uri, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    sanitized_uri = sanitize_uri(probe_uri)

    Logger.info("SourceProbe: starting ffprobe uri=#{sanitized_uri}")

    Logger.debug("SourceProbe: command=ffprobe #{Enum.join(ffprobe_args(sanitized_uri), " ")}")

    task =
      Task.async(fn ->
        System.cmd("ffprobe", ffprobe_args(probe_uri), stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        Logger.debug("SourceProbe: ffprobe completed successfully uri=#{sanitized_uri}")
        {:ok, output}

      {:ok, {output, exit_status}} ->
        error = normalize_ffprobe_error(output, exit_status)
        Logger.error("SourceProbe: ffprobe failed uri=#{sanitized_uri} error=#{inspect(error)}")
        {:error, error}

      {:exit, reason} ->
        Logger.error(
          "SourceProbe: ffprobe task crashed uri=#{sanitized_uri} reason=#{inspect(reason)}"
        )

        {:error, "ffprobe process crashed unexpectedly"}

      _ ->
        Logger.warning(
          "SourceProbe: ffprobe timed out uri=#{sanitized_uri} timeout_ms=#{timeout_ms}"
        )

        {:error, "ffprobe timed out after #{timeout_ms}ms"}
    end
  end

  defp ffprobe_args(probe_uri) do
    [
      "-v",
      "quiet",
      "-print_format",
      "json",
      "-show_streams",
      "-show_format",
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

  defp normalize_ffprobe_error(output, exit_status) do
    message =
      output
      |> String.trim()
      |> case do
        "" -> "ffprobe failed with exit status #{exit_status}"
        trimmed -> trimmed
      end

    sanitize_uri(message)
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
    Regex.replace(~r/(passphrase=)[^&\s]+/, value, "\\1#{@passphrase_mask}")
  end

  defp sanitize_uri(value), do: value
end

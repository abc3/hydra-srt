defmodule HydraSrt.SourceProbe do
  @moduledoc false

  require Logger

  alias HydraSrt.RouteHandler

  @ffprobe_timeout_ms 15_000
  @passphrase_mask "[REDACTED]"

  @spec probe(map()) :: {:ok, map()} | {:error, atom() | binary()}
  def probe(route_params) when is_map(route_params) do
    with {:ok, probe_uri} <- build_probe_uri(route_params),
         {:ok, ffprobe_path} <- find_ffprobe(),
         {:ok, raw_output} <- run_ffprobe(ffprobe_path, probe_uri),
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

  def probe(_), do: {:error, :invalid_source}

  @spec build_probe_uri(map()) :: {:ok, binary()} | {:error, atom() | binary()}
  def build_probe_uri(route_params) when is_map(route_params) do
    with {:ok, source} <- RouteHandler.source_from_record(route_params) do
      case source["type"] do
        "srtsrc" ->
          case {source["uri"], source["localport"] || source["port"]} do
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

        "udpsrc" ->
          case source["port"] do
            port when is_integer(port) ->
              address = source["address"] || "0.0.0.0"
              {:ok, "udp://#{address}:#{port}"}

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

      path ->
        Logger.debug("SourceProbe: using ffprobe executable path=#{path}")
        {:ok, path}
    end
  end

  defp run_ffprobe(ffprobe_path, probe_uri) do
    sanitized_uri = sanitize_uri(probe_uri)

    Logger.info("SourceProbe: starting ffprobe uri=#{sanitized_uri}")

    Logger.debug(
      "SourceProbe: command=#{ffprobe_path} #{Enum.join(ffprobe_args(sanitized_uri), " ")}"
    )

    task =
      Task.async(fn ->
        System.cmd(ffprobe_path, ffprobe_args(probe_uri), stderr_to_stdout: true)
      end)

    case Task.yield(task, @ffprobe_timeout_ms) || Task.shutdown(task, :brutal_kill) do
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
          "SourceProbe: ffprobe timed out uri=#{sanitized_uri} timeout_ms=#{@ffprobe_timeout_ms}"
        )

        {:error, "ffprobe timed out after #{@ffprobe_timeout_ms}ms"}
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

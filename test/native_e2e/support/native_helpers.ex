defmodule HydraSrt.E2E.Native.Helpers do
  @moduledoc false

  alias HydraSrt.E2E.Native.ProcessRegistry
  alias HydraSrt.TestSupport.E2EHelpers

  def ensure_prereqs! do
    ensure_ffmpeg!()
    ensure_rs_native_binary_present!()
    ProcessRegistry.ensure_table!()
    :ok
  end

  def ensure_ffmpeg! do
    case System.find_executable("ffmpeg") do
      nil -> raise ExUnit.AssertionError, message: "Native E2E requires ffmpeg in PATH"
      _ -> :ok
    end
  end

  def ensure_rs_native_binary_present! do
    binary = rs_native_binary_path()

    if File.exists?(binary),
      do: :ok,
      else:
        raise(
          "rs-native binary not found at #{binary}. Build it first with `make test_rs_native_e2e`."
        )
  end

  def rs_native_binary_path do
    Path.expand("rs-native/target/debug/hydra_srt_pipeline")
  end

  def free_srt_port!, do: E2EHelpers.tcp_free_port!()
  def free_udp_port!, do: E2EHelpers.udp_free_port!()

  def srt_to_udp_config(source_port, udp_port, opts \\ []) do
    source_uri = build_srt_uri("127.0.0.1", source_port, "listener", opts)

    %{
      "source" =>
        %{
          "type" => "srtsrc",
          "uri" => source_uri,
          "localaddress" => "127.0.0.1",
          "localport" => source_port,
          "auto-reconnect" => true,
          "keep-listening" => false,
          "mode" => "listener"
        }
        |> maybe_put_passphrase(opts),
      "sinks" => [
        %{
          "type" => "udpsink",
          "address" => "127.0.0.1",
          "host" => "127.0.0.1",
          "port" => udp_port,
          "hydra_destination_id" => "udp_demo",
          "hydra_destination_name" => "udp_demo",
          "hydra_destination_schema" => "UDP"
        }
      ]
    }
  end

  def start_ffmpeg_sender!(source_port, opts \\ []) do
    passphrase = Keyword.get(opts, :passphrase)
    pbkeylen = Keyword.get(opts, :pbkeylen, 16)
    duration = Keyword.get(opts, :duration, 20)

    srt_url =
      if is_binary(passphrase) do
        "srt://127.0.0.1:#{source_port}?mode=caller&streamid=test1&passphrase=#{passphrase}&pbkeylen=#{pbkeylen}"
      else
        "srt://127.0.0.1:#{source_port}?mode=caller&pkt_size=1316"
      end

    tag = "ffmpeg_rs_native_#{System.unique_integer([:positive])}"

    proc =
      E2EHelpers.start_port_logged!(
        "ffmpeg",
        [
          "-hide_banner",
          "-loglevel",
          "error",
          "-re",
          "-f",
          "lavfi",
          "-i",
          "testsrc2=size=1280x720:rate=30",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:sample_rate=48000",
          "-t",
          Integer.to_string(duration),
          "-c:v",
          "libx264",
          "-preset",
          "veryfast",
          "-tune",
          "zerolatency",
          "-pix_fmt",
          "yuv420p",
          "-g",
          "60",
          "-c:a",
          "aac",
          "-b:a",
          "128k",
          "-ar",
          "48000",
          "-ac",
          "2",
          "-f",
          "mpegts",
          srt_url
        ],
        tag
      )

    :ok =
      ProcessRegistry.register!(make_ref(), %{
        kind: :ffmpeg_sender,
        tag: tag,
        os_pid: proc.os_pid,
        port: proc.port
      })

    proc
  end

  def wait_until(fun, timeout_ms, interval_ms \\ 50) do
    E2EHelpers.wait_until(fun, timeout_ms, interval_ms)
  end

  defp build_srt_uri(host, port, mode, opts) do
    query =
      [{"mode", mode}]
      |> maybe_add_query("passphrase", Keyword.get(opts, :passphrase))
      |> maybe_add_query("pbkeylen", Keyword.get(opts, :pbkeylen))
      |> URI.encode_query()

    "srt://#{host}:#{port}?#{query}"
  end

  defp maybe_add_query(items, _key, nil), do: items
  defp maybe_add_query(items, _key, ""), do: items
  defp maybe_add_query(items, key, value), do: [{key, value} | items]

  defp maybe_put_passphrase(config, opts) do
    config
    |> maybe_put("passphrase", Keyword.get(opts, :passphrase))
    |> maybe_put("pbkeylen", Keyword.get(opts, :pbkeylen))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

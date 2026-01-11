defmodule HydraSrt.E2E.SrtPipelineE2ETest do
  use ExUnit.Case, async: false

  alias HydraSrt.TestSupport.E2EHelpers

  @moduletag :e2e

  setup_all do
    E2EHelpers.ensure_e2e_prereqs!()
    {:ok, base_url: E2EHelpers.base_url()}
  end

  test "SRT basic: stream arrives at sink (validated via srt-live-transmit -> UDP forwarding)", %{
    base_url: base_url
  } do
    token = E2EHelpers.api_login!(base_url, "admin", "password123")

    source_port = E2EHelpers.tcp_free_port!()
    sink_port = E2EHelpers.tcp_free_port!()
    udp_dummy_port = E2EHelpers.udp_free_port!()

    udp_counter = E2EHelpers.start_udp_counter!(udp_dummy_port)
    on_exit(fn -> E2EHelpers.stop_udp_counter!(udp_counter) end)

    route_id =
      E2EHelpers.api_create_route!(base_url, token, %{
        "name" => "e2e_srt_basic_ok",
        "exportStats" => false,
        "schema" => "SRT",
        "schema_options" => %{
          "localaddress" => "127.0.0.1",
          "localport" => source_port,
          "mode" => "listener"
        }
      })

    on_exit(fn ->
      E2EHelpers.api_stop_route(base_url, token, route_id)
      E2EHelpers.api_delete_route(base_url, token, route_id)
    end)

    :ok =
      E2EHelpers.api_create_destination!(base_url, token, route_id, %{
        "schema" => "SRT",
        "schema_options" => %{
          "localaddress" => "127.0.0.1",
          "localport" => sink_port,
          "mode" => "caller"
        }
      })

    rx =
      E2EHelpers.start_port_logged!(
        "srt-live-transmit",
        [
          "-v",
          "-stats",
          "1000",
          "-statspf",
          "default",
          "srt://127.0.0.1:#{sink_port}?mode=listener",
          "udp://127.0.0.1:#{udp_dummy_port}"
        ],
        "srt-live-transmit"
      )

    # Give srt-live-transmit a moment to bind and enter listen() before we start the pipeline.
    Process.sleep(750)

    :ok = E2EHelpers.api_start_route!(base_url, token, route_id)
    Process.sleep(750)

    tx =
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
          "6",
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
          "srt://127.0.0.1:#{source_port}?mode=caller"
        ],
        "ffmpeg"
      )

    on_exit(fn ->
      E2EHelpers.kill_port(tx)
      E2EHelpers.kill_port(rx)
    end)

    Process.sleep(6_000)
    assert E2EHelpers.await_tag_exit_status("ffmpeg", 10_000) == 0
    assert is_integer(E2EHelpers.await_srt_packets_received(100, 5_000))
  end
end

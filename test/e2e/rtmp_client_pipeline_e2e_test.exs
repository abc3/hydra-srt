defmodule HydraSrt.E2E.RtmpClientPipelineE2ETest do
  use ExUnit.Case, async: false

  alias HydraSrt.TestSupport.E2EHelpers

  @moduletag :e2e

  setup_all do
    E2EHelpers.ensure_e2e_prereqs!()
    E2EHelpers.ensure_ffprobe_executable!()
    {:ok, base_url: E2EHelpers.base_url()}
  end

  test "SRT source forwards to UDP and RTMP client destinations via Hydra RTMP proxy", %{
    base_url: base_url
  } do
    token = E2EHelpers.api_login!(base_url, "admin", "password123")
    suffix = System.unique_integer([:positive])
    source_port = E2EHelpers.tcp_free_port!()
    udp_dest_port = E2EHelpers.udp_free_port!()
    rtmp_path = "/e2e/rtmp_client_#{suffix}"
    rtmp_play_url = E2EHelpers.rtmp_play_url(rtmp_path)
    rtmp_publish_url = rtmp_play_url

    udp_counter = E2EHelpers.start_udp_counter!(udp_dest_port)
    on_exit(fn -> E2EHelpers.stop_udp_counter!(udp_counter) end)

    route_id =
      E2EHelpers.api_create_route!(base_url, token, %{
        "name" => "e2e_rtmp_client_#{suffix}",
        "schema" => "SRT",
        "localaddress" => "127.0.0.1",
        "localport" => source_port,
        "mode" => "listener"
      })

    on_exit(fn ->
      E2EHelpers.api_stop_route(base_url, token, route_id)
      E2EHelpers.api_delete_route(base_url, token, route_id)
    end)

    :ok =
      E2EHelpers.api_create_destination!(base_url, token, route_id, %{
        "schema" => "UDP",
        "name" => "udp_dest_rtmp_client_#{suffix}",
        "host" => "127.0.0.1",
        "port" => udp_dest_port
      })

    :ok =
      E2EHelpers.api_create_destination!(base_url, token, route_id, %{
        "schema" => "RTMP",
        "name" => "rtmp_dest_rtmp_client_#{suffix}",
        "location" => rtmp_publish_url
      })

    Process.sleep(E2EHelpers.e2e_startup_sleep_ms())

    :ok = E2EHelpers.api_start_route!(base_url, token, route_id)
    Process.sleep(E2EHelpers.e2e_startup_sleep_ms())

    tx =
      E2EHelpers.start_port_logged!(
        "ffmpeg",
        ffmpeg_srt_test_pattern_args(source_port),
        "ffmpeg-rtmp-client"
      )

    on_exit(fn -> E2EHelpers.kill_port(tx) end)

    E2EHelpers.wait_for_route_processing!(base_url, token, route_id,
      expected_destination_count: 2
    )

    assert {:ok, %{bytes: udp_bytes}} =
             E2EHelpers.await_udp_bytes(udp_counter, 20_000, 5_000)

    assert udp_bytes >= 20_000

    assert {:ok, %{streams: streams}} =
             E2EHelpers.await_rtmp_av_streams(rtmp_play_url, timeout_ms: 30_000)

    assert E2EHelpers.rtmp_streams_include_av?(streams)
    assert E2EHelpers.await_tag_exit_status("ffmpeg-rtmp-client", 10_000) == 0
  end

  defp ffmpeg_srt_test_pattern_args(source_port, _opts \\ []) do
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
    ]
  end
end

defmodule HydraSrt.E2E.RtmpClientPipelineE2ETest do
  use ExUnit.Case, async: false

  alias HydraSrt.TestSupport.E2EHelpers

  @moduletag :e2e

  setup_all do
    E2EHelpers.ensure_e2e_prereqs!()
    E2EHelpers.ensure_ffprobe_executable!()
    {:ok, base_url: E2EHelpers.base_url()}
  end

  test "SRT source forwards to RTMP client destination via Hydra RTMP proxy", %{
    base_url: base_url
  } do
    token = E2EHelpers.api_login!(base_url, "admin", "password123")
    suffix = System.unique_integer([:positive])
    source_port = E2EHelpers.tcp_free_port!()
    rtmp_path = "/e2e/rtmp_client_#{suffix}"
    rtmp_play_url = E2EHelpers.rtmp_play_url(rtmp_path)

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
        "schema" => "RTMP",
        "name" => "rtmp_dest_rtmp_client_#{suffix}",
        "location" => rtmp_play_url
      })

    Process.sleep(E2EHelpers.e2e_startup_sleep_ms())

    :ok = E2EHelpers.api_start_route!(base_url, token, route_id)
    Process.sleep(E2EHelpers.e2e_startup_sleep_ms())

    tx =
      E2EHelpers.start_port_logged!(
        "ffmpeg",
        E2EHelpers.ffmpeg_srt_test_pattern_args(source_port),
        "ffmpeg-rtmp-client"
      )

    on_exit(fn -> E2EHelpers.kill_port(tx) end)

    E2EHelpers.wait_for_route_processing!(base_url, token, route_id,
      expected_destination_count: 1
    )

    assert {:ok, %{streams: streams}} =
             E2EHelpers.await_rtmp_av_streams(rtmp_play_url, timeout_ms: 30_000)

    assert E2EHelpers.rtmp_streams_include_av?(streams)

    # The source streams well past the probe window so the publisher stays live while
    # ffprobe negotiates; once A/V is verified we stop it instead of waiting it out.
    E2EHelpers.kill_port(tx)
  end
end

defmodule HydraSrt.E2E.RtmpPublishGateE2ETest do
  use ExUnit.Case, async: false

  alias HydraSrt.TestSupport.E2EHelpers

  @moduletag :e2e

  # Min bytes of MPEG-TS we expect to flow out of the SRT destination before
  # declaring the RTMP publish -> SRT sink path healthy.
  @min_media_bytes 20_000

  setup_all do
    E2EHelpers.ensure_e2e_prereqs!()
    E2EHelpers.ensure_ffprobe_executable!()
    {:ok, base_url: E2EHelpers.base_url()}
  end

  defp rtmp_publish_args(rtmp_url, duration_sec, opts \\ []) do
    realtime? = Keyword.get(opts, :realtime, System.get_env("CI") != "true")

    [
      "-hide_banner",
      "-loglevel",
      "error"
    ] ++
      if(realtime?, do: ["-re"], else: []) ++
      [
        "-f",
        "lavfi",
        "-i",
        "testsrc2=size=1280x720:rate=30",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=440:sample_rate=48000",
        "-t",
        Integer.to_string(duration_sec),
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-tune",
        "zerolatency",
        "-pix_fmt",
        "yuv420p",
        "-profile:v",
        "baseline",
        "-g",
        "60",
        "-b:v",
        "2000k",
        "-c:a",
        "aac",
        "-b:a",
        "128k",
        "-ar",
        "48000",
        "-ac",
        "2",
        "-f",
        "flv",
        rtmp_url
      ]
  end

  defp create_rtmp_route(base_url, token, path, sink_port, name) do
    route_id =
      E2EHelpers.api_create_route!(base_url, token, %{
        "name" => name,
        "enabled" => true
      })

    _source_id =
      E2EHelpers.api_create_source!(base_url, token, route_id, %{
        "schema" => "RTMP",
        "name" => "#{name}-src",
        "path" => path,
        "position" => 0,
        "enabled" => true
      })

    :ok =
      E2EHelpers.api_create_destination!(base_url, token, route_id, %{
        "schema" => "SRT",
        "name" => "#{name}-dst",
        "localaddress" => "127.0.0.1",
        "localport" => sink_port,
        "mode" => "caller"
      })

    route_id
  end

  defp start_srt_receiver(sink_port, udp_port, tag) do
    E2EHelpers.start_port_logged!(
      "srt-live-transmit",
      [
        "-v",
        "srt://127.0.0.1:#{sink_port}?mode=listener",
        "udp://127.0.0.1:#{udp_port}"
      ],
      tag
    )
  end

  defp await_media_flow(udp_counter, timeout_ms) do
    assert {:ok, %{bytes: bytes}} =
             E2EHelpers.await_udp_bytes(udp_counter, @min_media_bytes, timeout_ms)

    assert bytes >= @min_media_bytes
    :ok
  end

  defp route_runtime_status(base_url, token, route_id) do
    route = E2EHelpers.api_get_route!(base_url, token, route_id)
    route["schema_status"] || route["status"]
  end

  defp publish_and_verify_media(base_url, token, route_id, rtmp_url, udp_counter, suffix) do
    publisher =
      E2EHelpers.start_port_logged!(
        "ffmpeg",
        rtmp_publish_args(rtmp_url, E2EHelpers.e2e_ffmpeg_stream_duration_sec()),
        "ffmpeg-pub-#{suffix}"
      )

    on_exit(fn -> E2EHelpers.kill_port(publisher) end)

    E2EHelpers.wait_for_route_processing!(base_url, token, route_id,
      expected_destination_count: 1
    )

    :ok = await_media_flow(udp_counter, 30_000)
    publisher
  end

  test "publish is rejected until the route is live, then accepted and forwarded to SRT", %{
    base_url: base_url
  } do
    token = E2EHelpers.api_login!(base_url, "admin", "password123")
    suffix = System.unique_integer([:positive])
    path = "/e2e/rtmp_gate_#{suffix}"
    rtmp_url = E2EHelpers.rtmp_play_url(path)
    sink_port = E2EHelpers.tcp_free_port!()
    udp_port = E2EHelpers.udp_free_port!()

    udp_counter = E2EHelpers.start_udp_counter!(udp_port)
    on_exit(fn -> E2EHelpers.stop_udp_counter!(udp_counter) end)

    route_id = create_rtmp_route(base_url, token, path, sink_port, "e2e_rtmp_gate_#{suffix}")

    on_exit(fn ->
      E2EHelpers.api_stop_route(base_url, token, route_id)
      E2EHelpers.api_delete_route(base_url, token, route_id)
    end)

    srt_rx = start_srt_receiver(sink_port, udp_port, "srt-rx-gate-#{suffix}")
    on_exit(fn -> E2EHelpers.kill_port(srt_rx) end)
    Process.sleep(E2EHelpers.e2e_startup_sleep_ms())

    # 1. Publish BEFORE the route is live -> the gate rejects with route_not_live.
    rejected =
      E2EHelpers.start_port_logged!(
        "ffmpeg",
        rtmp_publish_args(rtmp_url, 8),
        "ffmpeg-rejected-#{suffix}"
      )

    on_exit(fn -> E2EHelpers.kill_port(rejected) end)

    rejected_status = E2EHelpers.await_tag_exit_status("ffmpeg-rejected-#{suffix}", 15_000)
    assert rejected_status != 0

    # 2. Start the route, then publish -> accepted, and media flows to the SRT destination.
    :ok = E2EHelpers.api_start_route!(base_url, token, route_id)
    Process.sleep(E2EHelpers.e2e_startup_sleep_ms())

    publisher = publish_and_verify_media(base_url, token, route_id, rtmp_url, udp_counter, suffix)
    E2EHelpers.kill_port(publisher)
  end

  test "a second concurrent publisher on the same path is rejected", %{
    base_url: base_url
  } do
    token = E2EHelpers.api_login!(base_url, "admin", "password123")
    suffix = System.unique_integer([:positive])
    path = "/e2e/rtmp_conflict_#{suffix}"
    rtmp_url = E2EHelpers.rtmp_play_url(path)
    sink_port = E2EHelpers.tcp_free_port!()
    udp_port = E2EHelpers.udp_free_port!()

    udp_counter = E2EHelpers.start_udp_counter!(udp_port)
    on_exit(fn -> E2EHelpers.stop_udp_counter!(udp_counter) end)

    route_id = create_rtmp_route(base_url, token, path, sink_port, "e2e_rtmp_conflict_#{suffix}")

    on_exit(fn ->
      E2EHelpers.api_stop_route(base_url, token, route_id)
      E2EHelpers.api_delete_route(base_url, token, route_id)
    end)

    srt_rx = start_srt_receiver(sink_port, udp_port, "srt-rx-conflict-#{suffix}")
    on_exit(fn -> E2EHelpers.kill_port(srt_rx) end)
    Process.sleep(E2EHelpers.e2e_startup_sleep_ms())

    :ok = E2EHelpers.api_start_route!(base_url, token, route_id)
    Process.sleep(E2EHelpers.e2e_startup_sleep_ms())

    first = publish_and_verify_media(base_url, token, route_id, rtmp_url, udp_counter, suffix)

    second =
      E2EHelpers.start_port_logged!(
        "ffmpeg",
        rtmp_publish_args(rtmp_url, 8),
        "ffmpeg-conflict-second-#{suffix}"
      )

    on_exit(fn -> E2EHelpers.kill_port(second) end)

    second_status = E2EHelpers.await_tag_exit_status("ffmpeg-conflict-second-#{suffix}", 15_000)
    assert second_status != 0

    E2EHelpers.kill_port(first)
  end

  test "publisher drop is handled gracefully (EOS forward + disconnect event, route stays live)",
       %{
         base_url: base_url
       } do
    token = E2EHelpers.api_login!(base_url, "admin", "password123")
    suffix = System.unique_integer([:positive])
    path = "/e2e/rtmp_drop_#{suffix}"
    rtmp_url = E2EHelpers.rtmp_play_url(path)
    sink_port = E2EHelpers.tcp_free_port!()
    udp_port = E2EHelpers.udp_free_port!()

    udp_counter = E2EHelpers.start_udp_counter!(udp_port)
    on_exit(fn -> E2EHelpers.stop_udp_counter!(udp_counter) end)

    route_id = create_rtmp_route(base_url, token, path, sink_port, "e2e_rtmp_drop_#{suffix}")

    on_exit(fn ->
      E2EHelpers.api_stop_route(base_url, token, route_id)
      E2EHelpers.api_delete_route(base_url, token, route_id)
    end)

    Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{route_id}")

    srt_rx = start_srt_receiver(sink_port, udp_port, "srt-rx-drop-#{suffix}")
    on_exit(fn -> E2EHelpers.kill_port(srt_rx) end)
    Process.sleep(E2EHelpers.e2e_startup_sleep_ms())

    :ok = E2EHelpers.api_start_route!(base_url, token, route_id)
    Process.sleep(E2EHelpers.e2e_startup_sleep_ms())

    publisher = publish_and_verify_media(base_url, token, route_id, rtmp_url, udp_counter, suffix)

    # Drop the publisher. The RtmpServer tcp_closed handler must unregister the
    # path, clear the StreamCache, broadcast publish_eos (so the play-side
    # rtmpsrc sees EOF), and emit a publisher_disconnected event.
    E2EHelpers.kill_port(publisher)

    assert_receive {:event, %{"event_type" => "publisher_disconnected"}}, 10_000

    # The route stays live (rtmpsrc re-listens by default) instead of crashing —
    # EOS was forwarded gracefully.
    E2EHelpers.wait_until(
      fn ->
        route_runtime_status(base_url, token, route_id) in [
          "processing",
          "started",
          "starting",
          "reconnecting",
          "restarting"
        ]
      end,
      5_000,
      250
    )
  end
end

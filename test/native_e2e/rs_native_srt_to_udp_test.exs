defmodule HydraSrt.E2E.Native.RsNativeSrtToUdpTest do
  use ExUnit.Case, async: false

  alias HydraSrt.E2E.Native.Harness
  alias HydraSrt.E2E.Native.Helpers
  alias HydraSrt.E2E.Native.ProcessRegistry
  alias HydraSrt.E2E.Native.UdpListener
  alias HydraSrt.TestSupport.E2EHelpers

  @moduletag :native_e2e

  setup_all do
    Helpers.ensure_prereqs!()
    ProcessRegistry.cleanup_all!()
    :ok
  end

  setup context do
    ProcessRegistry.cleanup_all!()
    source_port = Helpers.free_srt_port!()
    udp_port = Helpers.free_udp_port!()

    {:ok, udp_listener} = UdpListener.start_link(port: udp_port, test_pid: self())

    config = Helpers.srt_to_udp_config(source_port, udp_port)
    config = maybe_deny_localhost(config, context)
    config = maybe_enable_thumbnail(config, context)

    {:ok, harness} =
      Harness.start_link(
        test_pid: self(),
        route_id: "rs_demo_#{System.unique_integer([:positive])}",
        config: config
      )

    on_exit(fn ->
      ProcessRegistry.cleanup_all!()
      if Process.alive?(harness), do: Harness.stop(harness)
      if Process.alive?(udp_listener), do: GenServer.stop(udp_listener, :normal, 5_000)
    end)

    {:ok,
     source_port: source_port, udp_port: udp_port, udp_listener: udp_listener, harness: harness}
  end

  test "forwards SRT input to UDP and reports live stats", %{
    source_port: source_port,
    udp_port: udp_port,
    udp_listener: udp_listener,
    harness: harness
  } do
    assert_receive {:rs_native_route_id, "rs_demo_" <> _}, 5_000

    sender = Helpers.start_ffmpeg_sender!(source_port)

    assert {:ok, stats} =
             Harness.await_stats(
               harness,
               fn
                 %{
                   "source" => %{"bytes_in_per_sec" => in_bps},
                   "destinations" => [%{"bytes_out_per_sec" => out_bps}],
                   "connected-callers" => callers
                 }
                 when is_number(in_bps) and in_bps > 0 and is_number(out_bps) and out_bps > 0 and
                        callers >= 1 ->
                   true

                 _ ->
                   false
               end,
               15_000
             )

    assert stats["source"]["type"] == "GstSRTSrc"
    assert hd(stats["destinations"])["schema"] == "UDP"

    assert {:ok, udp_stats} = UdpListener.await_packets(udp_listener, 5, 10_000)
    assert udp_stats.bytes > 0

    assert_receive {:udp_packet, ^udp_port, _}, 5_000
    assert is_binary(sender.tag)
  end

  test "emits stats payload shape required by graphs", %{
    source_port: source_port,
    harness: harness
  } do
    sender = Helpers.start_ffmpeg_sender!(source_port)

    assert {:ok, stats} =
             Harness.await_stats(
               harness,
               fn
                 %{
                   "source" => %{"bytes_in_per_sec" => in_bps, "bytes_in_total" => in_total},
                   "destinations" => [
                     %{
                       "id" => id,
                       "schema" => schema,
                       "name" => name,
                       "bytes_out_per_sec" => out_bps
                     }
                   ],
                   "connected-callers" => callers,
                   "callers" => caller_list
                 }
                 when is_number(in_bps) and is_number(in_total) and is_binary(id) and
                        is_binary(schema) and is_binary(name) and is_number(out_bps) and
                        is_integer(callers) and is_list(caller_list) ->
                   true

                 _ ->
                   false
               end,
               15_000
             )

    assert %{"bytes-received-total" => total_bytes} = stats["source"]["srt"]
    assert is_number(total_bytes)
    assert is_binary(sender.tag)
  end

  @tag skip: "local srtsrc does not emit caller-connecting for ffmpeg callers in this environment"
  @tag deny_localhost: true
  test "rejects SRT callers denied by source IP access rules", %{
    source_port: source_port,
    harness: harness
  } do
    assert_receive {:rs_native_route_id, "rs_demo_" <> _}, 5_000

    sender = Helpers.start_ffmpeg_sender!(source_port, duration: 3, streamid: "test1")

    assert_receive {:rs_native_event,
                    %{
                      "event" => "srt_access",
                      "ip" => "127.0.0.1",
                      "allowed" => false,
                      "reason" => "denied_list"
                    }},
                   10_000

    assert {:error, _latest} =
             Harness.await_stats(
               harness,
               fn
                 %{"connected-callers" => callers} when callers > 0 -> true
                 _ -> false
               end,
               2_000
             )

    assert is_binary(sender.tag)
  end

  @tag enable_thumbnail: true
  test "emits thumbnail JPEG event when enabled", %{
    source_port: source_port
  } do
    assert_receive {:rs_native_route_id, "rs_demo_" <> _}, 5_000

    sender =
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
          "testsrc2=size=640x360:rate=30",
          "-t",
          "8",
          "-c:v",
          "mpeg2video",
          "-pix_fmt",
          "yuv420p",
          "-f",
          "mpegts",
          "srt://127.0.0.1:#{source_port}?mode=caller&pkt_size=1316"
        ],
        "ffmpeg_thumbnail_native"
      )

    assert_receive {:rs_native_event,
                    %{
                      "event" => "thumbnail",
                      "source_id" => "native_source",
                      "content_type" => "image/jpeg",
                      "data_base64" => data_base64
                    }},
                   20_000

    assert {:ok, <<0xFF, 0xD8, _rest::binary>>} = Base.decode64(data_base64)
    assert sender.os_pid
  end

  def maybe_deny_localhost(config, %{deny_localhost: true}) do
    put_in(
      config,
      ["source"],
      Map.merge(config["source"], %{
        "streamid" => "test1",
        "authentication" => true,
        "hydra_limit_access" => true,
        "hydra_allowed_list" => [],
        "hydra_denied_list" => ["127.0.0.1"]
      })
    )
  end

  def maybe_deny_localhost(config, _context), do: config

  def maybe_enable_thumbnail(config, %{enable_thumbnail: true}) do
    put_in(
      config,
      ["source"],
      Map.merge(config["source"], %{
        "hydra_source_id" => "native_source",
        "hydra_thumbnail_enabled" => true,
        "hydra_thumbnail_interval_ms" => 1000,
        "hydra_thumbnail_capture_policy" => "running"
      })
    )
  end

  def maybe_enable_thumbnail(config, _context), do: config
end

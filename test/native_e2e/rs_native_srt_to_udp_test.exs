defmodule HydraSrt.E2E.Native.RsNativeSrtToUdpTest do
  use ExUnit.Case, async: false

  alias HydraSrt.E2E.Native.Harness
  alias HydraSrt.E2E.Native.Helpers
  alias HydraSrt.E2E.Native.ProcessRegistry
  alias HydraSrt.E2E.Native.UdpListener

  @moduletag :native_e2e

  setup_all do
    Helpers.ensure_prereqs!()
    ProcessRegistry.cleanup_all!()
    :ok
  end

  setup do
    ProcessRegistry.cleanup_all!()
    source_port = Helpers.free_srt_port!()
    udp_port = Helpers.free_udp_port!()

    {:ok, udp_listener} = UdpListener.start_link(port: udp_port, test_pid: self())

    config = Helpers.srt_to_udp_config(source_port, udp_port)

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
end

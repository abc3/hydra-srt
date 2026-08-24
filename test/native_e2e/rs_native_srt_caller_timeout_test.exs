defmodule HydraSrt.E2E.Native.RsNativeSrtCallerTimeoutTest do
  use ExUnit.Case, async: false

  alias HydraSrt.E2E.Native.Harness
  alias HydraSrt.E2E.Native.Helpers
  alias HydraSrt.E2E.Native.ProcessRegistry

  @moduletag :native_e2e

  # Must track native/crates/hydra-media/src/adapters/srt.rs::SRT_NO_DATA_SINCE_START_THRESHOLD_MS.
  # Deliberately not configurable (a route-level override would churn hydra-plan's
  # deny_unknown_fields plus every call site for a single test's convenience). That
  # means these tests genuinely wait out the real threshold: it is deterministic (the
  # peer accepts the SRT handshake and then sends nothing for a controlled window),
  # just slow - budget generously around it instead of trying to make it fast.
  @no_data_threshold_ms 30_000
  @slack_ms 20_000

  # How long the peer in the recovery test stays silent after it starts, before it
  # begins sending real media on its own (see Helpers.start_gst_srt_listener!/2,
  # `data_after_ms`). Must clear @no_data_threshold_ms with margin even accounting
  # for the peer's small head start over the route (the peer is launched, and
  # verified alive, before the harness that starts the route) and for a slow CI
  # runner - if data ever arrived before the threshold, the no-data health event
  # under test would never fire at all.
  @data_after_ms 45_000

  # How long to wait for "streaming" once the no-data event has already fired. The
  # peer keeps sending nothing until @data_after_ms after *it* started, so from the
  # route's later start this window only has to cover the remaining silence plus
  # encode/mux/transmit/detect latency, not the full @data_after_ms.
  @post_no_data_streaming_wait_ms 30_000

  setup_all do
    Helpers.ensure_rs_native_binary_present!()
    ProcessRegistry.ensure_table!()
    :ok
  end

  describe "peer that never sends data" do
    setup do
      ProcessRegistry.cleanup_all!()
      source_port = Helpers.free_srt_port!()
      udp_port = Helpers.free_udp_port!()
      route_id = "rs_srt_no_data_#{System.unique_integer([:positive])}"

      # A real SRT listener that accepts the caller's handshake and then never emits
      # a single buffer (see Helpers.start_gst_srt_listener!/2, `no_data: true`). The
      # connection genuinely completes - there is no bus error, no ICMP, nothing
      # platform-specific to go wrong - so the only thing that can happen next is the
      # "no data since start" health monitor firing once the threshold elapses. That
      # is the actual subject under test, independent of the OS-level failure timing
      # a dead/absorbing port would otherwise depend on.
      peer = Helpers.start_gst_srt_listener!(source_port, no_data: true)

      config = Helpers.srt_caller_source_config(source_port, udp_port, route_id: route_id)

      {:ok, harness} =
        Harness.start_link(
          test_pid: self(),
          route_id: route_id,
          config: config
        )

      on_exit(fn ->
        ProcessRegistry.cleanup_all!()
        if Process.alive?(harness), do: Harness.stop(harness)
        Helpers.stop_os_process!(peer)
      end)

      {:ok, harness: harness}
    end

    @tag timeout: @no_data_threshold_ms + @slack_ms + 15_000
    test "caller SRT source connected to a peer that never sends data stays alive, reports non-terminal health instead of dying",
         %{harness: harness} do
      assert_receive {:rs_native_route_id, "rs_srt_no_data_" <> _}, 5_000

      # The peer accepted the handshake in setup and has been sending nothing since:
      # the route must stay up and simply not report data - confirm no route_terminal
      # ever arrives, at any point in this test, not just before the threshold.
      refute_receive {:rs_native_event, %{"event" => "route_terminal"}},
                     @no_data_threshold_ms - 3_000

      assert_receive {:rs_native_event,
                      %{
                        "event" => "endpoint_health",
                        "endpoint_id" => "source_demo",
                        "direction" => "source",
                        "state" => "failed",
                        "reason_code" => "SRT_NO_DATA_SINCE_START",
                        "retryable" => true,
                        "retry_domain" => "route"
                      }},
                     @slack_ms + 5_000

      refute_receive {:rs_native_event, %{"event" => "route_terminal"}}, 3_000
      refute stats_show_flow?(Harness.latest_stats(harness))

      # The pipeline is genuinely still alive and connected - confirmed by the OS
      # process still being reachable, not merely by the absence of route_terminal
      # above.
      %{os_pid: os_pid} = Harness.state(harness)
      assert is_integer(os_pid)
      {_output, exit_code} = System.cmd("kill", ["-0", Integer.to_string(os_pid)])
      assert exit_code == 0, "native pipeline process #{os_pid} should still be running"
    end
  end

  describe "peer that starts sending after a delay" do
    setup do
      ProcessRegistry.cleanup_all!()
      source_port = Helpers.free_srt_port!()
      udp_port = Helpers.free_udp_port!()
      route_id = "rs_srt_no_data_#{System.unique_integer([:positive])}"

      # A single real SRT listener that stays connected for the whole test: it
      # accepts the caller's handshake, sends nothing for @data_after_ms, then
      # starts sending real media on its own - no process is killed or replaced,
      # so recovery is driven entirely by the route observing its still-open
      # connection start flowing (see Helpers.start_gst_srt_listener!/2,
      # `data_after_ms`).
      peer = Helpers.start_gst_srt_listener!(source_port, data_after_ms: @data_after_ms)

      config = Helpers.srt_caller_source_config(source_port, udp_port, route_id: route_id)

      {:ok, harness} =
        Harness.start_link(
          test_pid: self(),
          route_id: route_id,
          config: config
        )

      on_exit(fn ->
        ProcessRegistry.cleanup_all!()
        if Process.alive?(harness), do: Harness.stop(harness)
        Helpers.stop_os_process!(peer)
      end)

      {:ok, harness: harness}
    end

    @tag timeout: @no_data_threshold_ms + @slack_ms + @post_no_data_streaming_wait_ms + 20_000
    test "recovers automatically and reports healthy once the connected peer starts sending", %{
      harness: harness
    } do
      assert_receive {:rs_native_route_id, "rs_srt_no_data_" <> _}, 5_000

      assert_receive {:rs_native_event,
                      %{
                        "event" => "endpoint_health",
                        "endpoint_id" => "source_demo",
                        "direction" => "source",
                        "state" => "failed",
                        "reason_code" => "SRT_NO_DATA_SINCE_START"
                      }},
                     @no_data_threshold_ms + @slack_ms

      # Nobody restarts the route, nobody touches the process, nobody touches the
      # peer: it was already dialing this same, still-open connection the whole
      # time and simply starts sending on its own. Recovery has to be automatic,
      # driven entirely by this route's first-buffer probe observing that.
      assert_receive {:rs_native_event,
                      %{
                        "event" => "endpoint_health",
                        "endpoint_id" => "source_demo",
                        "direction" => "source",
                        "state" => "streaming",
                        "reason_code" => nil
                      }},
                     @post_no_data_streaming_wait_ms

      refute_receive {:rs_native_event, %{"event" => "route_terminal"}}, 2_000

      assert {:ok, stats} = Harness.await_stats(harness, &stats_show_flow?/1, 5_000)
      assert stats["source"]["type"] == "GstSRTSrc"
    end
  end

  defp stats_show_flow?(nil), do: false

  defp stats_show_flow?(%{"source" => %{"bytes_in_per_sec" => bytes_per_sec}})
       when is_number(bytes_per_sec),
       do: bytes_per_sec > 0

  defp stats_show_flow?(_), do: false
end

defmodule HydraSrt.E2E.Native.RsNativeSrtCallerTimeoutTest do
  use ExUnit.Case, async: false

  alias HydraSrt.E2E.Native.Harness
  alias HydraSrt.E2E.Native.Helpers
  alias HydraSrt.E2E.Native.ProcessRegistry

  @moduletag :native_e2e

  # Must track native/crates/hydra-media/src/adapters/srt.rs::SRT_NO_DATA_SINCE_START_THRESHOLD_MS.
  # Deliberately not configurable (a route-level override would churn hydra-plan's
  # deny_unknown_fields plus every call site for a single test's convenience). That
  # means this test genuinely waits out the real threshold: it is deterministic (a
  # caller pointed at a port nothing is bound on can never connect), just slow -
  # budget generously around it instead of trying to make it fast.
  @no_data_threshold_ms 30_000
  @slack_ms 20_000

  setup_all do
    Helpers.ensure_rs_native_binary_present!()
    ProcessRegistry.ensure_table!()
    :ok
  end

  setup do
    ProcessRegistry.cleanup_all!()
    source_port = Helpers.free_srt_port!()
    udp_port = Helpers.free_udp_port!()
    route_id = "rs_srt_no_data_#{System.unique_integer([:positive])}"

    # Hold source_port open with a peer that never speaks SRT. A caller
    # pointed at a genuinely closed local UDP port gets an ICMP
    # port-unreachable on Linux (but not on macOS), which makes srtsrc fail
    # fast on the GStreamer bus instead of retrying in silence - a different,
    # already-covered scenario, not the "no data since start" one these
    # tests are about. See Helpers.start_silent_udp_peer!/1.
    silent_peer = Helpers.start_silent_udp_peer!(source_port)

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
      Helpers.stop_silent_udp_peer!(silent_peer)
    end)

    {:ok, harness: harness, source_port: source_port, silent_peer: silent_peer}
  end

  @tag timeout: @no_data_threshold_ms + @slack_ms + 15_000
  test "caller SRT source with no listener stays alive, reports non-terminal health instead of dying",
       %{harness: harness} do
    assert_receive {:rs_native_route_id, "rs_srt_no_data_" <> _}, 5_000

    # Nothing is ever bound on source_port (see setup): the old design killed the
    # route here with a synthetic "connect timeout" terminal error. The route must
    # now stay up and simply not report data - confirm no route_terminal ever
    # arrives, at any point in this test, not just before the threshold.
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

    # The pipeline is genuinely still alive and srtsrc is still retrying on its
    # own - confirmed by the OS process still being reachable, not merely by the
    # absence of route_terminal above.
    %{os_pid: os_pid} = Harness.state(harness)
    assert is_integer(os_pid)
    {_output, exit_code} = System.cmd("kill", ["-0", Integer.to_string(os_pid)])
    assert exit_code == 0, "native pipeline process #{os_pid} should still be running"
  end

  @tag timeout: @no_data_threshold_ms + @slack_ms + 30_000
  test "recovers automatically and reports healthy once the far side comes back", %{
    harness: harness,
    source_port: source_port,
    silent_peer: silent_peer
  } do
    assert_receive {:rs_native_route_id, "rs_srt_no_data_" <> _}, 5_000

    assert_receive {:rs_native_event,
                    %{
                      "event" => "endpoint_health",
                      "state" => "failed",
                      "reason_code" => "SRT_NO_DATA_SINCE_START"
                    }},
                   @no_data_threshold_ms + @slack_ms

    # The far side comes back - a real SRT listener now appears on the exact port
    # the (still running, still retrying) caller has been dialing the whole time.
    # Nobody restarts the route, nobody touches the process: recovery has to be
    # automatic, driven entirely by srtsrc's own reconnect loop plus this route's
    # first-buffer probe. Release the silent peer first so the real listener can
    # bind the same port.
    Helpers.stop_silent_udp_peer!(silent_peer)
    listener = Helpers.start_gst_srt_listener!(source_port)

    on_exit(fn -> Helpers.stop_os_process!(listener) end)

    assert_receive {:rs_native_event,
                    %{
                      "event" => "endpoint_health",
                      "endpoint_id" => "source_demo",
                      "direction" => "source",
                      "state" => "streaming",
                      "reason_code" => nil
                    }},
                   15_000

    refute_receive {:rs_native_event, %{"event" => "route_terminal"}}, 2_000

    assert {:ok, stats} = Harness.await_stats(harness, &stats_show_flow?/1, 5_000)
    assert stats["source"]["type"] == "GstSRTSrc"
  end

  defp stats_show_flow?(nil), do: false

  defp stats_show_flow?(%{"source" => %{"bytes_in_per_sec" => bytes_per_sec}})
       when is_number(bytes_per_sec),
       do: bytes_per_sec > 0

  defp stats_show_flow?(_), do: false
end

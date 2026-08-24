defmodule HydraSrt.E2E.Native.RsNativeSrtWrongPassphraseTest do
  use ExUnit.Case, async: false

  alias HydraSrt.E2E.Native.Harness
  alias HydraSrt.E2E.Native.Helpers
  alias HydraSrt.E2E.Native.ProcessRegistry

  @moduletag :native_e2e

  @correct_passphrase "correct_pass_123"
  @wrong_passphrase "wrong_pass_456"

  setup_all do
    Helpers.ensure_rs_native_binary_present!()
    ProcessRegistry.ensure_table!()
    :ok
  end

  setup do
    ProcessRegistry.cleanup_all!()
    source_port = Helpers.free_srt_port!()
    udp_port = Helpers.free_udp_port!()

    listener = Helpers.start_gst_srt_listener!(source_port, passphrase: @correct_passphrase)

    on_exit(fn ->
      ProcessRegistry.cleanup_all!()
      Helpers.stop_os_process!(listener)
    end)

    {:ok, source_port: source_port, udp_port: udp_port}
  end

  test "a wrong passphrase against a real SRT peer classifies as SRT_AUTH_FAILED, retryable, and the process exits non-zero",
       %{source_port: source_port, udp_port: udp_port} do
    route_id = "rs_srt_wrongpass_#{System.unique_integer([:positive])}"

    config =
      Helpers.srt_caller_source_config(source_port, udp_port,
        route_id: route_id,
        passphrase: @wrong_passphrase
      )

    {:ok, harness} =
      Harness.start_link(test_pid: self(), route_id: route_id, config: config)

    on_exit(fn ->
      if Process.alive?(harness), do: Harness.stop(harness)
    end)

    assert_receive {:rs_native_route_id, ^route_id}, 5_000

    assert_receive {:rs_native_event,
                    %{
                      "event" => "endpoint_health",
                      "endpoint_id" => "source_demo",
                      "direction" => "source",
                      "state" => "failed",
                      "reason_code" => "SRT_AUTH_FAILED",
                      "retryable" => true,
                      "retry_domain" => "route"
                    }},
                   10_000

    assert_receive {:rs_native_event,
                    %{
                      "event" => "route_terminal",
                      "reason_code" => "SRT_AUTH_FAILED",
                      "retryable" => true,
                      "retry_domain" => "route"
                    }},
                   5_000

    # The wrong-passphrase text only ever appears in the debug string, not the
    # primary GError message - confirm the pipeline_log line carries it, proving
    # the operator-visible line actually says why (not just an opaque code).
    assert_receive {:rs_native_event,
                    %{
                      "event" => "pipeline_log",
                      "level" => "ERROR",
                      "category" => "gst_bus",
                      "message" => message
                    }},
                   5_000

    assert message =~ "Failed to authenticate: Incorrect passphrase"

    # A retryable route_terminal must not exit 0: the exit status is what
    # decides whether the supervising GenServer keeps its scheduled retry alive
    # or treats this as a normal stop and drops it.
    assert_receive {:rs_native_exit_status, ^route_id, status}, 10_000

    assert status != 0,
           "a retryable route_terminal must not exit the native process with status 0"
  end

  test "the correct passphrase against the same real SRT peer connects normally with no auth failure",
       %{source_port: source_port, udp_port: udp_port} do
    route_id = "rs_srt_rightpass_#{System.unique_integer([:positive])}"

    config =
      Helpers.srt_caller_source_config(source_port, udp_port,
        route_id: route_id,
        passphrase: @correct_passphrase
      )

    {:ok, harness} =
      Harness.start_link(test_pid: self(), route_id: route_id, config: config)

    on_exit(fn ->
      ProcessRegistry.cleanup_all!()
      if Process.alive?(harness), do: Harness.stop(harness)
    end)

    assert_receive {:rs_native_route_id, ^route_id}, 5_000

    assert {:ok, stats} =
             Harness.await_stats(
               harness,
               fn
                 %{"source" => %{"bytes_in_per_sec" => bps}} when is_number(bps) and bps > 0 ->
                   true

                 _ ->
                   false
               end,
               15_000
             )

    assert stats["source"]["type"] == "GstSRTSrc"

    refute_receive {:rs_native_event, %{"event" => "route_terminal"}}, 1_000

    refute_receive {:rs_native_event,
                    %{"event" => "endpoint_health", "reason_code" => "SRT_AUTH_FAILED"}},
                   1_000
  end
end

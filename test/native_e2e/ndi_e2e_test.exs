defmodule HydraSrt.E2E.Native.NdiE2ETest do
  use ExUnit.Case, async: false

  alias HydraSrt.E2E.Native.Harness
  alias HydraSrt.E2E.Native.Helpers
  alias HydraSrt.E2E.Native.ProcessRegistry
  alias HydraSrt.RouteHandler

  @moduletag :ndi_e2e
  @moduletag timeout: 45_000

  # Real-media cases carry @tag :ndi_runtime. When HYDRA_NDI_RUNTIME_DIR is
  # absent, test/test_helper.exs excludes that tag so they skip cleanly on
  # ExUnit 1.18 (setup cannot return {:skip, _}).

  setup_all do
    Helpers.ensure_ndi_prereqs!()
    ProcessRegistry.cleanup_all!()
    {capability, _} = Helpers.ndi_capability_status()
    {:ok, capability: capability}
  end

  setup do
    ProcessRegistry.cleanup_all!()

    on_exit(fn ->
      ProcessRegistry.cleanup_all!()
    end)

    :ok
  end

  test "HYDRA_NDI_RUNTIME_DIR maps to NDI_RUNTIME_DIR_V6 in native Port env" do
    previous = System.get_env("HYDRA_NDI_RUNTIME_DIR")
    System.put_env("HYDRA_NDI_RUNTIME_DIR", "/tmp/hydra-ndi-runtime-e2e")

    try do
      env = RouteHandler.native_pipeline_port_env(nil)
      assert {~c"GST_DEBUG", ~c"0"} in env
      assert {~c"NDI_RUNTIME_DIR_V6", ~c"/tmp/hydra-ndi-runtime-e2e"} in env

      assert RouteHandler.ndi_runtime_port_env() == [
               {~c"NDI_RUNTIME_DIR_V6", ~c"/tmp/hydra-ndi-runtime-e2e"}
             ]
    after
      restore_env("HYDRA_NDI_RUNTIME_DIR", previous)
    end
  end

  test "prohibited NDI proprietary artifacts are absent from the checkout" do
    assert :ok = Helpers.assert_no_prohibited_ndi_artifacts!()
  end

  test "discovery and probe fail closed when NDI is unavailable", %{capability: capability} do
    expected =
      case capability do
        :plugin_missing -> "NDI_PLUGIN_MISSING"
        :runtime_missing -> "NDI_RUNTIME_MISSING"
        :available -> "NDI_RUNTIME_MISSING"
      end

    env =
      case capability do
        :available -> Helpers.native_port_env_without_runtime()
        _ -> Helpers.native_port_env()
      end

    {discovery_status, discovery_events} =
      Helpers.run_ndi_discovery!(env: env, timeout_ms: 15_000)

    assert discovery_status == 0

    capability_events =
      Enum.filter(discovery_events, &match?(%{"event" => "ndi_capability"}, &1))

    assert length(capability_events) == 1
    assert hd(capability_events)["ok"] == false
    assert hd(capability_events)["reason_code"] == expected

    {probe_status, probe_events} =
      Helpers.run_ndi_probe!(Helpers.ndi_probe_input(), env: env, timeout_ms: 20_000)

    assert probe_status == 0
    probe_results = Enum.filter(probe_events, &match?(%{"event" => "probe_result"}, &1))
    assert length(probe_results) == 1
    assert hd(probe_results)["ok"] == false
    assert hd(probe_results)["reason_code"] == expected
  end

  test "NDI route start fails closed with classified route_terminal", %{capability: capability} do
    previous = System.get_env("HYDRA_NDI_RUNTIME_DIR")

    if capability == :available do
      System.delete_env("HYDRA_NDI_RUNTIME_DIR")
    end

    try do
      # NDI→NDI only (mixed NDI/legacy is rejected by the planner).
      config =
        Helpers.ndi_to_ndi_config(
          source_name: "Hydra Absent Source #{System.unique_integer([:positive])}",
          media_policy: "video_only",
          connect_timeout_ms: 2_000,
          receive_timeout_ms: 2_000,
          track_discovery_timeout_ms: 2_000
        )

      harness_env =
        case capability do
          :available -> Helpers.native_port_env_without_runtime()
          _ -> Helpers.native_port_env()
        end

      # What the route fails closed with is decided by what its child process can
      # actually load, not by what this env asks for: unsetting the runtime dirs
      # still leaves the platform loader search path. Classify the exact env the
      # route is about to get, so a host that resolves libndi anyway is reported
      # as an unusable environment instead of being blamed on the classifier.
      {child_capability, _} = Helpers.ndi_capability_status(env: harness_env)

      expected =
        case child_capability do
          # Missing factories are rejected while the graph is built.
          :plugin_missing ->
            ["NDI_PLUGIN_MISSING"]

          # ndisrc and ndisink both fail NULL→READY when libndi cannot be loaded,
          # so the whole state change fails synchronously. The bus carries the
          # sink's element error, and the sink is state-changed first, so either
          # the drained bus watch (destination attribution) or the start error
          # itself reaches route_terminal first.
          :runtime_missing ->
            ["NDI_SENDER_START_FAILED", "NDI_RUNTIME_MISSING"]

          :available ->
            flunk("""
            NDI runtime still loadable in the route child env, so the fail-closed \
            path cannot be exercised here. Remove libndi from the loader search \
            path of the test host (NDI_RUNTIME_DIR_V6/V5 are already cleared).\
            """)
        end

      {:ok, harness} =
        Harness.start_link(
          test_pid: self(),
          route_id: config["route_id"],
          config: config,
          env: harness_env
        )

      assert_receive {:rs_native_event,
                      %{
                        "event" => "route_terminal",
                        "reason_code" => reason_code
                      }},
                     20_000

      assert reason_code in expected

      assert_receive {:rs_native_exit_status, _route_id, status}, 10_000
      assert status != 0

      # The harness self-terminates once the native process exits on the
      # fail-closed path, so a stop here can race with that shutdown.
      if Process.alive?(harness) do
        try do
          Harness.stop(harness)
        catch
          :exit, _ -> :ok
        end
      end
    after
      restore_env("HYDRA_NDI_RUNTIME_DIR", previous)
    end
  end

  @tag :ndi_runtime
  test "NDI->NDI AV path negotiates and advertises when runtime is present" do
    sender_name = "Hydra CI AV #{System.unique_integer([:positive])}"

    sender =
      Helpers.start_gst_ndi_sender!(name: sender_name, media_policy: "video_and_audio_required")

    on_exit(fn -> Helpers.stop_os_process!(sender) end)

    resolved_source = wait_for_sender_visible!(sender)

    out_name = "Hydra CI Out AV #{System.unique_integer([:positive])}"

    config =
      Helpers.ndi_to_ndi_config(
        source_name: resolved_source,
        sender_name: out_name,
        media_policy: "video_and_audio_required"
      )

    {:ok, harness} =
      Harness.start_link(test_pid: self(), route_id: config["route_id"], config: config)

    on_exit(fn -> if Process.alive?(harness), do: Harness.stop(harness) end)

    assert_receive {:rs_native_event,
                    %{
                      "event" => "endpoint_health",
                      "transport" => "ndi",
                      "direction" => "destination",
                      "state" => "advertising"
                    }},
                   30_000

    assert {:ok, _stats} =
             Harness.await_stats(
               harness,
               fn
                 %{"source" => %{"bytes_in_per_sec" => bps}} when is_number(bps) and bps > 0 ->
                   true

                 _ ->
                   false
               end,
               30_000
             )
  end

  @tag :ndi_runtime
  test "NDI->NDI video-only path when runtime is present" do
    run_ndi_media_policy_case!("video_only")
  end

  @tag :ndi_runtime
  test "NDI->NDI audio-only path when runtime is present" do
    run_ndi_media_policy_case!("audio_only")
  end

  @tag :ndi_runtime
  test "discovery enumerates a live sender over mDNS when runtime is present" do
    sender_name = "Hydra CI Discover #{System.unique_integer([:positive])}"
    sender = Helpers.start_gst_ndi_sender!(name: sender_name, media_policy: "video_only")
    on_exit(fn -> Helpers.stop_os_process!(sender) end)

    resolved_source = wait_for_sender_visible!(sender)

    # NDI advertises "MACHINE (ndi-name)", so the resolved name carries the fixture
    # name rather than equalling it.
    assert String.contains?(resolved_source, sender_name)
  end

  @tag :ndi_runtime
  test "probe returns ok against a live sender and classifies an absent sender" do
    sender_name = "Hydra CI Probe #{System.unique_integer([:positive])}"
    sender = Helpers.start_gst_ndi_sender!(name: sender_name, media_policy: "video_only")
    on_exit(fn -> Helpers.stop_os_process!(sender) end)

    resolved_source = wait_for_sender_visible!(sender)

    {_status, live_events} =
      Helpers.run_ndi_probe!(
        Helpers.ndi_probe_input(source_name: resolved_source, media_policy: "video_only"),
        timeout_ms: 20_000
      )

    live = Enum.find(live_events, &match?(%{"event" => "probe_result"}, &1))
    assert live["ok"] == true
    assert is_binary(live["video_caps"]) and live["video_caps"] != ""

    {_status2, absent_events} =
      Helpers.run_ndi_probe!(
        Helpers.ndi_probe_input(
          source_name: "Hydra Absent #{System.unique_integer([:positive])}",
          media_policy: "video_only",
          track_discovery_timeout_ms: 2_000,
          connect_timeout_ms: 2_000,
          receive_timeout_ms: 2_000
        ),
        timeout_ms: 15_000
      )

    absent = Enum.find(absent_events, &match?(%{"event" => "probe_result"}, &1))
    assert absent["ok"] == false

    assert absent["reason_code"] in [
             "NDI_REQUIRED_VIDEO_MISSING",
             "NDI_RECEIVE_TIMEOUT",
             "NDI_RUNTIME_MISSING",
             "RUNTIME_ERROR"
           ]
  end

  @tag :ndi_runtime
  test "source loss emits a single retryable route_terminal" do
    sender_name = "Hydra CI Loss #{System.unique_integer([:positive])}"
    sender = Helpers.start_gst_ndi_sender!(name: sender_name, media_policy: "video_only")
    resolved_source = wait_for_sender_visible!(sender)

    config =
      Helpers.ndi_to_ndi_config(
        source_name: resolved_source,
        media_policy: "video_only",
        receive_timeout_ms: 3_000,
        track_discovery_timeout_ms: 5_000
      )

    {:ok, harness} =
      Harness.start_link(test_pid: self(), route_id: config["route_id"], config: config)

    on_exit(fn -> if Process.alive?(harness), do: Harness.stop(harness) end)

    assert {:ok, _} =
             Harness.await_stats(
               harness,
               fn
                 %{"source" => %{"bytes_in_per_sec" => bps}} when is_number(bps) and bps > 0 ->
                   true

                 _ ->
                   false
               end,
               30_000
             )

    Helpers.stop_os_process!(sender)

    assert_receive {:rs_native_event,
                    %{
                      "event" => "route_terminal",
                      "reason_code" => reason,
                      "retryable" => true
                    }},
                   30_000

    assert reason in ["NDI_RECEIVE_TIMEOUT", "NDI_SOURCE_EOS", "RUNTIME_ERROR"]

    # Single-owner: at most one route_terminal for this process.
    refute_receive {:rs_native_event, %{"event" => "route_terminal"}}, 1_000
  end

  @tag :ndi_runtime
  test "repeated start/stop leaves no orphan native OS process" do
    sender_name = "Hydra CI Life #{System.unique_integer([:positive])}"
    sender = Helpers.start_gst_ndi_sender!(name: sender_name, media_policy: "video_only")
    on_exit(fn -> Helpers.stop_os_process!(sender) end)
    resolved_source = wait_for_sender_visible!(sender)

    Enum.each(1..2, fn _ ->
      config =
        Helpers.ndi_to_ndi_config(source_name: resolved_source, media_policy: "video_only")

      {:ok, harness} =
        Harness.start_link(test_pid: self(), route_id: config["route_id"], config: config)

      state = Harness.state(harness)
      os_pid = state.os_pid
      assert is_integer(os_pid)

      Harness.stop(harness)
      Process.sleep(200)

      assert {_out, 1} =
               System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end)
  end

  def run_ndi_media_policy_case!(media_policy) do
    sender_name = "Hydra CI #{media_policy} #{System.unique_integer([:positive])}"
    sender = Helpers.start_gst_ndi_sender!(name: sender_name, media_policy: media_policy)
    on_exit(fn -> Helpers.stop_os_process!(sender) end)
    resolved_source = wait_for_sender_visible!(sender)

    config =
      Helpers.ndi_to_ndi_config(source_name: resolved_source, media_policy: media_policy)

    {:ok, harness} =
      Harness.start_link(test_pid: self(), route_id: config["route_id"], config: config)

    on_exit(fn -> if Process.alive?(harness), do: Harness.stop(harness) end)

    assert {:ok, _} =
             Harness.await_stats(
               harness,
               fn
                 %{"source" => %{"bytes_in_per_sec" => bps}} when is_number(bps) and bps > 0 ->
                   true

                 _ ->
                   false
               end,
               30_000
             )
  end

  # Kept small on purpose: E2EHelpers.wait_until/3 multiplies this by 4 on CI, and the
  # discovery server answers unicast queries in well under a second. A larger budget
  # only guarantees the module timeout fires first, replacing the flunk (which carries
  # the sender output) with an opaque ExUnit.TimeoutError that carries nothing.
  def wait_for_sender_visible!(sender, timeout_ms \\ 5_000) do
    if resolved = wait_until_discovery_sees!(sender, timeout_ms) do
      resolved
    else
      last = Helpers.last_helper_output()

      flunk("""
      NDI sender #{inspect(sender_display_name(sender))} not visible via ndi-discovery within #{timeout_ms}ms

      --- last ndi-discovery invocation ---
      args: #{inspect(last.args)}
      exit_status: #{inspect(last.exit_status)}
      timed_out?: #{inspect(last.timed_out?)}
      raw output:
      #{last.raw}
      """)
    end
  end

  def sender_display_name(%{name: name}) when is_binary(name), do: name
  def sender_display_name(name) when is_binary(name), do: name

  # NDI advertises a source as "MACHINE (ndi-name)". The fixture only knows the
  # bare ndi-name, so discovery matches on a substring — but `ndisrc` resolves a
  # source by its full advertised name. Return the resolved name so callers can
  # feed exactly that into a route or probe config; matching by substring here and
  # then connecting by the bare name is what leaves a route receiving zero bytes.
  def wait_until_discovery_sees!(sender, timeout_ms) do
    sender_name = sender_display_name(sender)
    Process.delete(:hydra_ndi_resolved_source_name)

    try do
      Helpers.wait_until(
        fn ->
          {_status, events} = Helpers.run_ndi_discovery!(timeout_ms: 4_000)

          case discovered_display_name(events, sender_name) do
            nil ->
              false

            resolved ->
              Process.put(:hydra_ndi_resolved_source_name, resolved)
              true
          end
        end,
        timeout_ms,
        1_000
      )

      Process.get(:hydra_ndi_resolved_source_name)
    rescue
      RuntimeError -> nil
    end
  end

  def discovered_display_name(events, sender_name) do
    events
    |> Enum.flat_map(fn
      %{"event" => "ndi_device_snapshot", "devices" => devices} when is_list(devices) -> devices
      %{"event" => "ndi_device_added", "device" => device} -> [device]
      _ -> []
    end)
    |> Enum.map(&to_string(&1["display_name"] || ""))
    |> Enum.find(&String.contains?(&1, sender_name))
  end

  def restore_env(name, nil), do: System.delete_env(name)
  def restore_env(name, value) when is_binary(value), do: System.put_env(name, value)
end

defmodule HydraSrt.Ndi.DiscoveryTest do
  use ExUnit.Case, async: false

  alias HydraSrt.Ndi.Discovery

  setup do
    previous = Application.get_env(:hydra_srt, :ndi, :__unset__)
    Application.put_env(:hydra_srt, :ndi, enabled: true, receive: true, send: false)

    on_exit(fn ->
      case previous do
        :__unset__ -> Application.delete_env(:hydra_srt, :ndi)
        value -> Application.put_env(:hydra_srt, :ndi, value)
      end
    end)

    :ok
  end

  test "disabled mode never launches a helper and reports NDI_DISABLED" do
    Application.put_env(:hydra_srt, :ndi, enabled: false)
    parent = self()

    launcher = fn path, args ->
      send(parent, {:launched, path, args})
      make_ref()
    end

    name = unique_name()
    assert {:ok, pid} = Discovery.start_link(name: name, port_launcher: launcher)
    on_exit(fn -> stop_discovery(pid) end)

    refute_receive {:launched, _, _}, 50

    snapshot = Discovery.snapshot(name)
    assert snapshot.devices == []
    assert snapshot.stale == false
    assert snapshot.capability == %{ok: false, reason_code: "NDI_DISABLED"}
  end

  test "connecting state reports NDI_HELPER_PENDING not nil reason" do
    {name, _port} = start_with_fake_port()

    snapshot = Discovery.snapshot(name)
    assert snapshot.capability == %{ok: false, reason_code: "NDI_HELPER_PENDING"}
  end

  test "parses snapshot, added, and removed JSONL events from injectable port" do
    {name, port} = start_with_fake_port()

    send_line(name, port, %{
      "event" => "ndi_device_snapshot",
      "devices" => [
        device("Cam A"),
        device("Cam B")
      ],
      "truncated" => false
    })

    snapshot = Discovery.snapshot(name)
    assert length(snapshot.devices) == 2
    assert snapshot.stale == false
    assert snapshot.capability == %{ok: true, reason_code: nil}
    assert snapshot.truncated == false

    send_line(name, port, %{
      "event" => "ndi_device_added",
      "device" => device("Cam C")
    })

    assert length(Discovery.snapshot(name).devices) == 3

    send_line(name, port, %{
      "event" => "ndi_device_removed",
      "device" => device("Cam B")
    })

    names =
      name
      |> Discovery.snapshot()
      |> Map.fetch!(:devices)
      |> Enum.map(& &1["display_name"])
      |> Enum.sort()

    assert names == ["Cam A", "Cam C"]
  end

  test "ndi_capability event updates capability state" do
    {name, port} = start_with_fake_port()

    send_line(name, port, %{
      "event" => "ndi_capability",
      "ok" => false,
      "reason_code" => "NDI_PLUGIN_MISSING"
    })

    snapshot = Discovery.snapshot(name)
    assert snapshot.capability == %{ok: false, reason_code: "NDI_PLUGIN_MISSING"}
    assert snapshot.stale == false
  end

  test "finding 2: ok:false capability does not reset consecutive_failures so UNHEALTHY triggers" do
    parent = self()

    launcher = fn path, args ->
      ref = make_ref()
      send(parent, {:launched, ref, path, args})
      ref
    end

    name = unique_name()

    assert {:ok, pid} =
             Discovery.start_link(
               name: name,
               port_launcher: launcher,
               backoff_fun: fn _failures -> 10 end
             )

    on_exit(fn -> stop_discovery(pid) end)

    for _ <- 1..5 do
      port = wait_for_launch()

      send_line(name, port, %{
        "event" => "ndi_capability",
        "ok" => false,
        "reason_code" => "NDI_PLUGIN_MISSING"
      })

      send(pid, {port, {:exit_status, 1}})
    end

    assert eventually(
             fn ->
               Discovery.snapshot(name).capability ==
                 %{ok: false, reason_code: "NDI_HELPER_UNHEALTHY"}
             end,
             2_000
           )
  end

  test "add/remove deltas do not promote capability to ok after MISSING" do
    {name, port} = start_with_fake_port()

    send_line(name, port, %{
      "event" => "ndi_capability",
      "ok" => false,
      "reason_code" => "NDI_PLUGIN_MISSING"
    })

    send_line(name, port, %{
      "event" => "ndi_device_added",
      "device" => device("Cam A")
    })

    assert Discovery.snapshot(name).capability ==
             %{ok: false, reason_code: "NDI_PLUGIN_MISSING"}

    send_line(name, port, %{
      "event" => "ndi_device_removed",
      "device" => device("Cam A")
    })

    assert Discovery.snapshot(name).capability ==
             %{ok: false, reason_code: "NDI_PLUGIN_MISSING"}
  end

  test "helper exit below unhealthy threshold sets pending not prior ok" do
    {name, port} = start_with_fake_port()

    send_line(name, port, %{
      "event" => "ndi_device_snapshot",
      "devices" => [device("Cam A")],
      "truncated" => false
    })

    assert Discovery.snapshot(name).capability.ok

    send(name, {port, {:exit_status, 1}})

    assert eventually(
             fn ->
               Discovery.snapshot(name).capability ==
                 %{ok: false, reason_code: "NDI_HELPER_PENDING"}
             end,
             500
           )
  end

  test "marks snapshot stale after configured TTL" do
    assert Discovery.snapshot_stale?(nil, 100, 15_000)
    refute Discovery.snapshot_stale?(100, 100 + 14_999, 15_000)
    assert Discovery.snapshot_stale?(100, 100 + 15_001, 15_000)

    {name, port} = start_with_fake_port(stale_after_ms: 30)

    send_line(name, port, %{
      "event" => "ndi_device_snapshot",
      "devices" => [device("Cam A")],
      "truncated" => false
    })

    refute Discovery.snapshot(name).stale
    assert eventually(fn -> Discovery.snapshot(name).stale end, 200)
  end

  test "caps retained devices at 256 and sets truncated" do
    {name, port} = start_with_fake_port()

    devices = Enum.map(1..257, fn i -> device("Cam #{i}") end)

    send_line(name, port, %{
      "event" => "ndi_device_snapshot",
      "devices" => devices,
      "truncated" => true
    })

    snapshot = Discovery.snapshot(name)
    assert length(snapshot.devices) == 256
    assert snapshot.truncated == true
  end

  test "finding 7: upsert at 256 devices evicts oldest and keeps newest" do
    devices = Enum.map(1..256, fn i -> device("Cam #{i}") end)
    assert length(devices) == Discovery.max_devices()

    {capped, truncated} = Discovery.upsert_device(devices, device("Cam NEW"))
    assert truncated
    assert length(capped) == 256
    names = Enum.map(capped, & &1["display_name"])
    assert "Cam NEW" in names
    refute "Cam 1" in names
    assert List.last(names) == "Cam NEW"
  end

  test "finding 1: accepts a full-native-sized snapshot above the old 64KB guard" do
    {name, port} = start_with_fake_port()

    # ~100KB of device payload — would have been dropped by the old 64KB guard.
    devices =
      Enum.map(1..80, fn i ->
        pad = String.duplicate("x", 200)

        %{
          "display_name" => "Cam #{i} #{pad}",
          "device_class" => "Source/Network #{pad}",
          "caps" => "application/x-ndi #{pad}",
          "properties" => pad
        }
      end)

    payload = %{
      "event" => "ndi_device_snapshot",
      "helper_instance_id" => "helper-1",
      "devices" => devices,
      "truncated" => false
    }

    line = Jason.encode!(payload)
    assert byte_size(line) > 65_536
    assert byte_size(line) < Discovery.max_line_bytes()

    send(name, {port, {:data, line <> "\n"}})
    _ = Discovery.snapshot(name)

    snapshot = Discovery.snapshot(name)
    assert length(snapshot.devices) == 80
    assert snapshot.capability == %{ok: true, reason_code: nil}
  end

  test "finding 1: lone oversize when idle marks unhealthy and remains refreshable" do
    {name, port} = start_with_fake_port()

    oversize = String.duplicate("x", Discovery.max_line_bytes() + 1)
    send(name, {port, {:data, oversize <> "\n"}})
    _ = Discovery.snapshot(name)

    assert Discovery.snapshot(name).capability ==
             %{ok: false, reason_code: "NDI_HELPER_UNHEALTHY"}

    assert :ok = Discovery.refresh(name)
    assert_receive {:launched, _port2, _path, ["ndi-discovery", "--helper-instance-id", _]}, 1_000
  end

  test "finding 6: oversize line is skipped and rest of chunk still parsed" do
    {name, port} = start_with_fake_port()

    oversize = String.duplicate("x", Discovery.max_line_bytes() + 1)

    good =
      Jason.encode!(%{
        "event" => "ndi_device_snapshot",
        "devices" => [device("Cam After")],
        "truncated" => false
      })

    send(name, {port, {:data, oversize <> "\n" <> good <> "\n"}})
    _ = Discovery.snapshot(name)

    snapshot = Discovery.snapshot(name)
    assert [%{"display_name" => "Cam After"}] = snapshot.devices
    assert snapshot.capability == %{ok: true, reason_code: nil}
  end

  test "finding 3: oversize during in-flight refresh clears coalesce and runs trailing refresh" do
    parent = self()
    launches = :counters.new(1, [])

    launcher = fn path, args ->
      :counters.add(launches, 1, 1)
      ref = make_ref()
      send(parent, {:launched, ref, path, args})
      ref
    end

    name = unique_name()
    assert {:ok, pid} = Discovery.start_link(name: name, port_launcher: launcher)
    on_exit(fn -> stop_discovery(pid) end)

    assert_receive {:launched, _port1, _path, ["ndi-discovery", "--helper-instance-id", _]}

    assert :ok = Discovery.refresh(name)
    assert_receive {:launched, port2, _path, ["ndi-discovery", "--helper-instance-id", _]}
    assert :counters.get(launches, 1) == 2

    # Coalesced refresh while in-flight must not be lost when the first line is dropped.
    assert :ok = Discovery.refresh(name)
    refute_receive {:launched, _, _, _}, 50

    oversize = String.duplicate("x", Discovery.max_line_bytes() + 1)
    send(name, {port2, {:data, oversize <> "\n"}})
    _ = Discovery.snapshot(name)

    # Oversize cleared in-flight and ran the pending trailing refresh.
    assert_receive {:launched, _port3, _path, ["ndi-discovery", "--helper-instance-id", _]}, 1_000
    assert :counters.get(launches, 1) == 3
  end

  test "finding 3+9: coalesced refresh sets pending and runs one trailing restart" do
    parent = self()
    launches = :counters.new(1, [])

    launcher = fn path, args ->
      :counters.add(launches, 1, 1)
      ref = make_ref()
      send(parent, {:launched, ref, path, args})
      ref
    end

    name = unique_name()
    assert {:ok, pid} = Discovery.start_link(name: name, port_launcher: launcher)
    on_exit(fn -> stop_discovery(pid) end)

    assert_receive {:launched, _port1, _path, ["ndi-discovery", "--helper-instance-id", _]}
    assert :counters.get(launches, 1) == 1

    assert :ok = Discovery.refresh(name)
    assert_receive {:launched, port2, _path, ["ndi-discovery", "--helper-instance-id", _]}
    assert :counters.get(launches, 1) == 2

    # Coalesce while in-flight — must not drop the request permanently.
    assert :ok = Discovery.refresh(name)
    assert :ok = Discovery.refresh(name)
    refute_receive {:launched, _, _, _}, 50
    assert :counters.get(launches, 1) == 2

    # Completing in-flight (snapshot) must run exactly one trailing refresh.
    send_line(name, port2, %{
      "event" => "ndi_device_snapshot",
      "devices" => [device("Cam A")],
      "truncated" => false
    })

    assert_receive {:launched, _port3, _path, ["ndi-discovery", "--helper-instance-id", _]}, 1_000
    assert :counters.get(launches, 1) == 3
    refute_receive {:launched, _, _, _}, 50
  end

  test "refresh coalesces while one restart is already in flight" do
    parent = self()
    launches = :counters.new(1, [])

    launcher = fn path, args ->
      :counters.add(launches, 1, 1)
      ref = make_ref()
      send(parent, {:launched, ref, path, args})
      ref
    end

    name = unique_name()
    assert {:ok, pid} = Discovery.start_link(name: name, port_launcher: launcher)
    on_exit(fn -> stop_discovery(pid) end)

    assert_receive {:launched, _port1, _path, ["ndi-discovery", "--helper-instance-id", _]}
    assert :counters.get(launches, 1) == 1

    assert :ok = Discovery.refresh(name)
    assert_receive {:launched, _port2, _path, ["ndi-discovery", "--helper-instance-id", _]}
    assert :counters.get(launches, 1) == 2

    assert :ok = Discovery.refresh(name)
    assert :ok = Discovery.refresh(name)
    refute_receive {:launched, _, _, _}, 50
    assert :counters.get(launches, 1) == 2
  end

  test "runtime FeaturePolicy disable/enable via refresh starts and stops helper" do
    parent = self()

    launcher = fn path, args ->
      ref = make_ref()
      send(parent, {:launched, ref, path, args})
      ref
    end

    name = unique_name()
    assert {:ok, pid} = Discovery.start_link(name: name, port_launcher: launcher)
    on_exit(fn -> stop_discovery(pid) end)

    assert_receive {:launched, _port1, _path, ["ndi-discovery", "--helper-instance-id", _]}

    Application.put_env(:hydra_srt, :ndi, enabled: false)
    assert :ok = Discovery.refresh(name)

    assert Discovery.snapshot(name).capability ==
             %{ok: false, reason_code: "NDI_DISABLED"}

    refute_receive {:launched, _, _, _}, 50

    Application.put_env(:hydra_srt, :ndi, enabled: true, receive: true, send: false)
    assert :ok = Discovery.refresh(name)

    assert_receive {:launched, _port2, _path, ["ndi-discovery", "--helper-instance-id", _]}, 1_000

    assert Discovery.snapshot(name).capability ==
             %{ok: false, reason_code: "NDI_HELPER_PENDING"}
  end

  test "five consecutive exits without events set NDI_HELPER_UNHEALTHY" do
    parent = self()

    launcher = fn path, args ->
      ref = make_ref()
      send(parent, {:launched, ref, path, args})
      ref
    end

    name = unique_name()

    assert {:ok, pid} =
             Discovery.start_link(
               name: name,
               port_launcher: launcher,
               backoff_fun: fn _failures -> 10 end
             )

    on_exit(fn -> stop_discovery(pid) end)

    for _ <- 1..5 do
      port = wait_for_launch()
      send(pid, {port, {:exit_status, 1}})
    end

    assert eventually(
             fn ->
               Discovery.snapshot(name).capability ==
                 %{ok: false, reason_code: "NDI_HELPER_UNHEALTHY"}
             end,
             2_000
           )
  end

  test "next_backoff_ms grows exponentially and caps near 30s" do
    :rand.seed(:exsss, {1, 2, 3})
    assert Discovery.next_backoff_ms(1) >= 1_000
    assert Discovery.next_backoff_ms(1) <= 1_000 + div(1_000, 4) + 1

    :rand.seed(:exsss, {1, 2, 3})
    delay = Discovery.next_backoff_ms(10)
    assert delay >= 30_000
    assert delay <= 30_000 + div(30_000, 4) + 1
  end

  test "native_discovery_args matches helper spawn contract" do
    assert Discovery.native_discovery_args("abc") == [
             "ndi-discovery",
             "--helper-instance-id",
             "abc"
           ]
  end

  test "discovery_port_env maps HYDRA_NDI_RUNTIME_DIR to NDI_RUNTIME_DIR_V6" do
    previous = System.get_env("HYDRA_NDI_RUNTIME_DIR")
    System.put_env("HYDRA_NDI_RUNTIME_DIR", "/tmp/hydra-ndi-runtime-discovery-test")

    try do
      env = Discovery.discovery_port_env()
      assert {~c"GST_DEBUG", ~c"0"} in env
      assert {~c"GST_DEBUG_NO_COLOR", ~c"1"} in env
      assert {~c"NDI_RUNTIME_DIR_V6", ~c"/tmp/hydra-ndi-runtime-discovery-test"} in env

      assert env ==
               [{~c"GST_DEBUG", ~c"0"}, {~c"GST_DEBUG_NO_COLOR", ~c"1"}] ++
                 HydraSrt.RouteHandler.ndi_runtime_port_env()
    after
      case previous do
        nil -> System.delete_env("HYDRA_NDI_RUNTIME_DIR")
        value -> System.put_env("HYDRA_NDI_RUNTIME_DIR", value)
      end
    end
  end

  test "discovery_port_env omits NDI_RUNTIME_DIR_V6 when product knob is unset" do
    previous = System.get_env("HYDRA_NDI_RUNTIME_DIR")
    System.delete_env("HYDRA_NDI_RUNTIME_DIR")

    try do
      env = Discovery.discovery_port_env()
      refute Enum.any?(env, fn {k, _} -> k == ~c"NDI_RUNTIME_DIR_V6" end)
      assert {~c"GST_DEBUG", ~c"0"} in env
    after
      case previous do
        nil -> System.delete_env("HYDRA_NDI_RUNTIME_DIR")
        value -> System.put_env("HYDRA_NDI_RUNTIME_DIR", value)
      end
    end
  end

  test "pure helpers normalize devices and reject blank names" do
    assert Discovery.normalize_device(%{
             "display_name" => "A",
             "device_class" => "Source/Network"
           }) ==
             %{
               "display_name" => "A",
               "device_class" => "Source/Network",
               "caps" => "",
               "properties" => ""
             }

    assert Discovery.normalize_device(%{"display_name" => ""}) == nil
    assert Discovery.normalize_device(%{}) == nil
  end

  def start_with_fake_port(opts \\ []) do
    parent = self()

    launcher = fn path, args ->
      ref = make_ref()
      send(parent, {:launched, ref, path, args})
      ref
    end

    name = unique_name()

    assert {:ok, pid} =
             Discovery.start_link(Keyword.merge([name: name, port_launcher: launcher], opts))

    on_exit(fn -> stop_discovery(pid) end)

    assert_receive {:launched, port, _path, ["ndi-discovery", "--helper-instance-id", _id]}
    {name, port}
  end

  def stop_discovery(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal, 5_000)
    else
      :ok
    end
  rescue
    _ -> :ok
  catch
    # GenServer.stop exits (:noproc / :timeout); rescue alone does not catch exits.
    :exit, _ -> :ok
  end

  def send_line(server, port, payload) do
    line = Jason.encode!(payload) <> "\n"
    send(server, {port, {:data, line}})
    _ = Discovery.snapshot(server)
    :ok
  end

  def device(name) do
    %{
      "display_name" => name,
      "device_class" => "Source/Network",
      "caps" => "application/x-ndi",
      "properties" => ""
    }
  end

  def unique_name do
    :"ndi_discovery_test_#{System.unique_integer([:positive])}"
  end

  def wait_for_launch do
    receive do
      {:launched, port, _path, _args} -> port
    after
      5_000 -> flunk("helper was not launched")
    end
  end

  def eventually(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  def do_eventually(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition not met before deadline")
      else
        Process.sleep(10)
        do_eventually(fun, deadline)
      end
    end
  end
end

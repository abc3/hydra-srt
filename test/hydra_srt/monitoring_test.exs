defmodule HydraSrt.MonitoringTest do
  use ExUnit.Case
  alias HydraSrt.Monitoring.OsMon
  alias HydraSrt.ProcessMonitor
  alias HydraSrt.SignalHandler
  alias HydraSrt.ErlSysMon

  test "OsMon returns valid system stats" do
    stats = OsMon.get_all_stats()
    assert is_map(stats)
    assert is_float(stats.ram)
    assert stats.ram >= 0 and stats.ram <= 100
    assert is_map(stats.cpu_la)
    assert is_float(stats.cpu_la.avg1)
    assert is_float(stats.cpu_la.avg5)
    assert is_float(stats.cpu_la.avg15)
  end

  test "OsMon ram_usage returns valid percentage" do
    ram_usage = OsMon.ram_usage()
    assert is_float(ram_usage)
    assert ram_usage >= 0 and ram_usage <= 100
  end

  test "OsMon cpu_la returns valid load averages" do
    cpu_la = OsMon.cpu_la()
    assert is_map(cpu_la)
    assert Map.has_key?(cpu_la, :avg1)
    assert Map.has_key?(cpu_la, :avg5)
    assert Map.has_key?(cpu_la, :avg15)
    assert is_float(cpu_la.avg1)
    assert is_float(cpu_la.avg5)
    assert is_float(cpu_la.avg15)
  end

  test "OsMon cpu_util returns valid utilization" do
    cpu_util = OsMon.cpu_util()
    assert is_float(cpu_util) or match?({:error, _}, cpu_util)

    if is_float(cpu_util) do
      assert cpu_util >= 0 and cpu_util <= 100
    end
  end

  test "ProcessMonitor lists pipeline processes" do
    processes = ProcessMonitor.list_pipeline_processes()
    assert is_list(processes)

    for process <- processes do
      assert is_map(process)
      assert Map.has_key?(process, :pid)
      assert Map.has_key?(process, :cpu)
      assert Map.has_key?(process, :memory)
      assert Map.has_key?(process, :memory_percent)
      assert Map.has_key?(process, :memory_bytes)
      assert Map.has_key?(process, :swap_percent)
      assert Map.has_key?(process, :swap_bytes)
      assert Map.has_key?(process, :user)
      assert Map.has_key?(process, :start_time)
      assert Map.has_key?(process, :command)
    end
  end

  test "ProcessMonitor lists detailed pipeline processes" do
    processes = ProcessMonitor.list_pipeline_processes_detailed()
    assert is_list(processes)

    for process <- processes do
      assert is_map(process)
      assert Map.has_key?(process, :pid)
      assert Map.has_key?(process, :cpu)
      assert Map.has_key?(process, :memory_percent)
      assert Map.has_key?(process, :memory_bytes)
      assert Map.has_key?(process, :virtual_memory)
      assert Map.has_key?(process, :resident_memory)
      assert Map.has_key?(process, :swap_percent)
      assert Map.has_key?(process, :swap_bytes)
      assert Map.has_key?(process, :cpu_time)
      assert Map.has_key?(process, :state)
      assert Map.has_key?(process, :ppid)
      assert Map.has_key?(process, :user)
      assert Map.has_key?(process, :start_time)
      assert Map.has_key?(process, :command)
    end
  end

  test "SignalHandler initializes with empty state" do
    assert {:ok, %{}} = SignalHandler.init([])
  end

  test "SignalHandler handles events" do
    signal = {:signal, :sigterm}
    state = %{}
    assert {:ok, %{}} = SignalHandler.handle_event(signal, state)
  end

  test "ErlSysMon initializes correctly" do
    assert {:ok, []} = ErlSysMon.init([])
  end

  test "ErlSysMon handles info messages" do
    msg = {:monitor, :test_pid, :test_event}
    state = []
    assert {:noreply, []} = ErlSysMon.handle_info(msg, state)
  end
end

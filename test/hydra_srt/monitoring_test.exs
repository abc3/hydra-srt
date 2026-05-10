defmodule HydraSrt.MonitoringTest do
  use ExUnit.Case
  alias HydraSrt.Monitoring.OsMon
  alias HydraSrt.Monitoring.NodeStats
  alias HydraSrt.PromEx.Plugins.OsMon, as: PromExOsMon
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

  test "OsMon ram_usage_from_memory_data prefers available_memory when present" do
    usage =
      OsMon.ram_usage_from_memory_data(
        total_memory: 1000,
        available_memory: 300,
        free_memory: 10,
        cached_memory: 10,
        buffered_memory: 10
      )

    assert usage == 70.0
  end

  test "OsMon ram_usage_from_memory_data falls back to free cached buffered" do
    usage =
      OsMon.ram_usage_from_memory_data(
        total_memory: 1000,
        free_memory: 200,
        cached_memory: 100,
        buffered_memory: 100
      )

    assert usage == 60.0
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

  test "OsMon swap_usage returns valid percentage or nil" do
    swap_usage = OsMon.swap_usage()
    assert is_float(swap_usage) or is_nil(swap_usage)

    if is_float(swap_usage) do
      assert swap_usage >= 0 and swap_usage <= 100
    end
  end

  test "OsMon parse_darwin_swap_usage parses unit values" do
    output = "vm.swapusage: total = 6.00G  used = 4.96G  free = 1.04G  (encrypted)"
    usage = OsMon.parse_darwin_swap_usage(output)
    assert usage > 82.6 and usage < 82.7
  end

  test "OsMon parse_darwin_swap_usage parses values without unit as bytes" do
    output = "vm.swapusage: total = 1000  used = 250  free = 750"
    usage = OsMon.parse_darwin_swap_usage(output)
    assert usage == 25.0
  end

  test "OsMon parse_linux_swap_usage parses meminfo" do
    meminfo = """
    MemTotal:       16384000 kB
    SwapTotal:       6291456 kB
    SwapFree:        1048576 kB
    """

    usage = OsMon.parse_linux_swap_usage(meminfo)
    assert usage == 83.33333333333334
  end

  test "PromEx OsMon execute_metrics populates persistent_term cache" do
    PromExOsMon.execute_metrics()
    stats = PromExOsMon.get_stats()
    assert is_map(stats)
    assert is_float(stats.ram)
    assert stats.ram >= 0 and stats.ram <= 100
    assert is_map(stats.cpu_la)
    assert is_float(stats.cpu_la.avg1)
    assert is_float(stats.cpu_la.avg5)
    assert is_float(stats.cpu_la.avg15)
    assert is_float(stats.swap) or is_nil(stats.swap)
  end

  test "NodeStats.all_nodes returns current node stats" do
    stats = NodeStats.all_nodes()
    assert is_list(stats)
    assert length(stats) == 1

    [self_stat] = stats
    assert self_stat.status == "self"
    assert Map.has_key?(self_stat, :host)
    assert Map.has_key?(self_stat, :cpu)
    assert Map.has_key?(self_stat, :ram)
    assert Map.has_key?(self_stat, :swap)
    assert Map.has_key?(self_stat, :la)
  end

  test "NodeStats.self_node_stats returns self node" do
    stats = NodeStats.self_node_stats()
    assert stats.status == "self"
    assert stats.host == node()
    assert Map.has_key?(stats, :la)
  end

  test "NodeStats.format_float formats floats correctly" do
    assert NodeStats.format_float(1.5) == "1.5"
    assert NodeStats.format_float(nil) == "N/A"
    assert NodeStats.format_float(:bad) == "N/A"
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

  test "ProcessMonitor matches pipeline processes by exact route id argument" do
    processes = [
      %{
        pid: 111,
        command:
          "/Users/sts/dev/hydra/_build/dev/lib/hydra_srt/priv/native/hydra_srt_pipeline route-1"
      },
      %{
        pid: 222,
        command:
          "/Users/sts/dev/hydra/_build/dev/lib/hydra_srt/priv/native/hydra_srt_pipeline route-10"
      },
      %{pid: 333, command: "grep route-1"},
      %{pid: 444, command: "/bin/other route-1"}
    ]

    assert [%{pid: 111}] = ProcessMonitor.route_pipeline_processes("route-1", processes)
  end

  test "ProcessMonitor handles different operating systems" do
    case :os.type() do
      {:unix, :darwin} ->
        assert is_list(ProcessMonitor.list_pipeline_processes())
        assert is_list(ProcessMonitor.list_pipeline_processes_detailed())

      {:unix, :linux} ->
        assert is_list(ProcessMonitor.list_pipeline_processes())
        assert is_list(ProcessMonitor.list_pipeline_processes_detailed())

      _ ->
        assert {:error, "Unsupported operating system"} = ProcessMonitor.list_pipeline_processes()

        assert {:error, "Unsupported operating system"} =
                 ProcessMonitor.list_pipeline_processes_detailed()
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

  test "SignalHandler handles multiple signal types" do
    signals = [:sigterm, :sigint, :sighup, :sigquit]
    state = %{}

    for signal_type <- signals do
      signal = {:signal, signal_type}
      assert {:ok, %{}} = SignalHandler.handle_event(signal, state)
    end
  end

  test "ErlSysMon initializes correctly" do
    assert {:ok, []} = ErlSysMon.init([])
  end

  test "ErlSysMon handles info messages" do
    msg = {:monitor, :test_pid, :test_event}
    state = []
    assert {:noreply, []} = ErlSysMon.handle_info(msg, state)
  end

  test "ErlSysMon handles various monitor messages" do
    messages = [
      {:monitor, :test_pid, :busy_port},
      {:monitor, :test_pid, :busy_dist_port},
      {:monitor, :test_pid, {:long_gc, 500}},
      {:monitor, :test_pid, {:long_schedule, 200}}
    ]

    state = []

    for msg <- messages do
      assert {:noreply, []} = ErlSysMon.handle_info(msg, state)
    end
  end
end

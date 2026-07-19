defmodule HydraSrt.ProcessMonitorNdiHelperTest do
  use ExUnit.Case, async: true

  alias HydraSrt.ProcessMonitor

  test "classifies route and ndi_helper process kinds" do
    route_cmd =
      "/priv/native/hydra_srt_pipeline route --route-id route-1 --process-instance-id piid-1"

    helper_cmd =
      "/priv/native/hydra_srt_pipeline ndi-discovery --helper-instance-id helper-1"

    probe_cmd =
      "/priv/native/hydra_srt_pipeline ndi-probe --probe-instance-id probe-1"

    assert ProcessMonitor.pipeline_process_kind(%{command: route_cmd}) == :route
    assert ProcessMonitor.pipeline_process_kind(%{command: helper_cmd}) == :ndi_helper
    assert ProcessMonitor.pipeline_process_kind(%{command: probe_cmd}) == :ndi_helper
    assert ProcessMonitor.pipeline_process_kind(%{command: "grep hydra"}) == :other
  end

  test "finding 12: ndi-discovery as route-id flag value stays :route not :ndi_helper" do
    # Old bare argv membership would mis-classify this as :ndi_helper and skip cleanup.
    route_cmd =
      "/priv/native/hydra_srt_pipeline route --route-id ndi-discovery --process-instance-id piid-1"

    probe_as_route_id =
      "/priv/native/hydra_srt_pipeline route --route-id ndi-probe --process-instance-id piid-2"

    assert ProcessMonitor.pipeline_process_kind(%{command: route_cmd}) == :route
    assert ProcessMonitor.pipeline_process_kind(%{command: probe_as_route_id}) == :route

    assert ProcessMonitor.route_pipeline_process?(
             %{command: route_cmd},
             "ndi-discovery"
           )

    assert [%{pid: 1}] =
             ProcessMonitor.route_pipeline_processes("ndi-discovery", [
               %{pid: 1, command: route_cmd}
             ])
  end

  test "subcommand after binary is required for :ndi_helper" do
    args_helper = [
      "/priv/native/hydra_srt_pipeline",
      "ndi-discovery",
      "--helper-instance-id",
      "h1"
    ]

    args_route = [
      "/priv/native/hydra_srt_pipeline",
      "route",
      "--route-id",
      "ndi-discovery"
    ]

    assert ProcessMonitor.pipeline_process_kind_from_args(args_helper) == :ndi_helper
    assert ProcessMonitor.pipeline_process_kind_from_args(args_route) == :route
    assert ProcessMonitor.pipeline_binary_index(args_helper) == 0
  end

  test "excludes ndi helpers from route cleanup even if a route id token appears" do
    route_id = "route-1"

    processes = [
      %{
        pid: 111,
        command:
          "/priv/native/hydra_srt_pipeline route --route-id route-1 --process-instance-id piid-1"
      },
      %{
        pid: 222,
        command: "/priv/native/hydra_srt_pipeline ndi-discovery --helper-instance-id route-1"
      },
      %{
        pid: 333,
        command: "/priv/native/hydra_srt_pipeline ndi-probe --probe-instance-id route-1"
      }
    ]

    assert [%{pid: 111}] = ProcessMonitor.route_pipeline_processes(route_id, processes)
    refute ProcessMonitor.route_pipeline_process?(Enum.at(processes, 1), route_id)
    refute ProcessMonitor.route_pipeline_process?(Enum.at(processes, 2), route_id)
  end

  test "route cleanup still matches exact route id for route kind" do
    processes = [
      %{
        pid: 111,
        command:
          "/priv/native/hydra_srt_pipeline route --route-id route-1 --process-instance-id piid-1"
      },
      %{
        pid: 222,
        command:
          "/priv/native/hydra_srt_pipeline route --route-id route-10 --process-instance-id piid-10"
      }
    ]

    assert [%{pid: 111}] = ProcessMonitor.route_pipeline_processes("route-1", processes)
  end
end

defmodule HydraSrt.DashboardTest do
  use ExUnit.Case, async: true

  alias HydraSrt.Dashboard

  test "route_summary uses runtime statuses and endpoint schemas" do
    routes = [
      %{
        "schema_status" => "processing",
        "sources" => [%{"schema" => "SRT"}, %{"schema" => "UDP"}],
        "destinations" => [%{"schema" => "SRT"}, %{"schema" => "RTMP"}]
      },
      %{
        "schema_status" => "reconnecting",
        "sources" => [%{"schema" => "SRT"}],
        "destinations" => [%{"schema" => "UDP"}]
      }
    ]

    assert %{
             total: 2,
             statuses: %{"processing" => 1, "reconnecting" => 1},
             source_protocols: %{"SRT" => 2, "UDP" => 1},
             destination_protocols: %{"RTMP" => 1, "SRT" => 1, "UDP" => 1}
           } = Dashboard.route_summary(routes)
  end

  test "failover_summary detects active and unavailable backup sources" do
    routes = [
      %{
        "enabled" => true,
        "schema_status" => "processing",
        "active_source_id" => "backup-1",
        "sources" => [
          %{"id" => "primary-1", "position" => 0, "enabled" => true},
          %{"id" => "backup-1", "position" => 1, "enabled" => true}
        ]
      },
      %{
        "enabled" => true,
        "schema_status" => "processing",
        "active_source_id" => "primary-2",
        "sources" => [
          %{"id" => "primary-2", "position" => 0, "enabled" => true},
          %{"id" => "backup-2", "position" => 1, "enabled" => false}
        ]
      }
    ]

    events = %{last_failover_at: "2026-06-23T10:00:00Z", failbacks_today: 2}

    assert %{
             on_backup: 1,
             backup_unavailable: 1,
             last_failover_at: "2026-06-23T10:00:00Z",
             failbacks_today: 2
           } = Dashboard.failover_summary(routes, events)
  end

  test "network_series aggregates all interface rates" do
    points = [
      %{
        "net_in_eth0" => 100.0,
        "net_out_eth0" => 200.0,
        "net_in_eth1" => 25.0,
        "net_out_eth1" => 50.0,
        :timestamp => "2026-06-23T10:00:00Z",
        :cpu => 10.0
      }
    ]

    assert [
             %{
               timestamp: "2026-06-23T10:00:00Z",
               input: 125.0,
               output: 250.0
             }
           ] = Dashboard.network_series(points)
  end

  test "reconcile_status_series ends with the current route snapshot" do
    historical = [%{timestamp: "2026-06-23T09:00:00Z", processing: 2, stopped: 1}]

    routes = [
      %{"schema_status" => "stopped"},
      %{"schema_status" => "stopped"},
      %{"schema_status" => "failed"}
    ]

    assert [
             %{
               processing: 0,
               starting: 0,
               reconnecting: 0,
               restarting: 0,
               failed: 1,
               stopped: 2,
               other: 0,
               timestamp: "2026-06-23T10:00:00Z"
             }
           ] = Dashboard.reconcile_status_series(historical, routes, "2026-06-23T10:00:00Z")
  end

  test "route_status_counts includes zero counts for every status key" do
    routes = [%{"schema_status" => "processing"}]

    assert %{
             processing: 1,
             starting: 0,
             reconnecting: 0,
             restarting: 0,
             failed: 0,
             stopped: 0,
             other: 0
           } = Dashboard.route_status_counts(routes)
  end
end

defmodule HydraSrt.DashboardTest do
  use ExUnit.Case, async: false

  alias HydraSrt.Dashboard
  alias HydraSrt.Stats.VictoriaMetrics

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

  test "event_summary returns an available empty summary for no routes" do
    assert %{available: true, last_failover_at: nil, failbacks_today: 0, latest_by_route: %{}} =
             Dashboard.event_summary([])
  end

  describe "event_summary server-side narrowing" do
    test "scopes the export to the requested routes with a regex matcher" do
      test_pid = self()
      :ok = :meck.new(HydraSrt.Stats.VictoriaMetrics, [:passthrough])

      :meck.expect(HydraSrt.Stats.VictoriaMetrics, :export_series, fn match_expr, _from, _to ->
        send(test_pid, {:match_expr, match_expr})
        {:ok, []}
      end)

      try do
        assert %{available: true} = Dashboard.event_summary(["route-1", "route-2"])

        assert_received {:match_expr, match_expr}
        assert match_expr == VictoriaMetrics.event_selector_for_route_ids(["route-1", "route-2"])
      after
        :meck.unload(HydraSrt.Stats.VictoriaMetrics)
      end
    end

    test "chunks large route sets into regex-constrained exports" do
      test_pid = self()
      route_ids = Enum.map(1..51, &"route-#{&1}")
      batch1_ids = Enum.map(1..50, &"route-#{&1}")
      batch2_ids = ["route-51"]
      :ok = :meck.new(HydraSrt.Stats.VictoriaMetrics, [:passthrough])

      :meck.expect(HydraSrt.Stats.VictoriaMetrics, :export_series, fn match_expr, _from, _to ->
        send(test_pid, {:match_expr, match_expr})
        {:ok, []}
      end)

      try do
        assert %{available: true} = Dashboard.event_summary(route_ids)

        assert_received {:match_expr, batch1_expr}
        assert_received {:match_expr, batch2_expr}
        refute_received {:match_expr, _}

        assert batch1_expr == VictoriaMetrics.event_selector_for_route_ids(batch1_ids)
        assert batch2_expr == VictoriaMetrics.event_selector_for_route_ids(batch2_ids)
        refute batch1_expr == "hydra_srt_route_event"
        refute batch2_expr == "hydra_srt_route_event"
      after
        :meck.unload(HydraSrt.Stats.VictoriaMetrics)
      end
    end

    test "propagates export errors from any chunked batch" do
      route_ids = Enum.map(1..51, &"route-#{&1}")
      :ok = :meck.new(HydraSrt.Stats.VictoriaMetrics, [:passthrough])

      :meck.expect(HydraSrt.Stats.VictoriaMetrics, :export_series, fn _match_expr, _from, _to ->
        {:error, :timeout}
      end)

      try do
        assert %{available: false} = Dashboard.event_summary(route_ids)
      after
        :meck.unload(HydraSrt.Stats.VictoriaMetrics)
      end
    end
  end
end

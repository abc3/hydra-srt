defmodule HydraSrt.Stats.AnalyticsTest do
  use ExUnit.Case, async: true

  alias HydraSrt.Monitoring.OsMon
  alias HydraSrt.Stats.Analytics
  alias HydraSrt.Stats.Duckdb

  test "build_query_params resolves known window" do
    assert {:ok, params} = Analytics.build_query_params(%{"window" => "last_hour"})
    assert params.window == "last_hour"
    assert params.bucket_ms == 30_000
    assert DateTime.compare(params.from, params.to) == :lt
  end

  test "build_query_params downsamples 24h window with default max_points" do
    assert {:ok, params} = Analytics.build_query_params(%{"window" => "last_24_hour"})
    assert params.bucket_ms == 300_000
  end

  test "build_query_params honors max_points override" do
    assert {:ok, params} =
             Analytics.build_query_params(%{"window" => "last_24_hour", "max_points" => "120"})

    assert params.bucket_ms == 900_000
  end

  test "route_status_point_series ignores events for deleted routes" do
    from_dt = ~U[2026-06-23 09:00:00Z]
    to_dt = ~U[2026-06-23 09:01:00Z]
    bucket_ms = 60_000
    allowed_route_ids = MapSet.new(["route-1"])

    route_statuses = %{"route-1" => "processing"}

    event_rows = [
      %{
        "route_id" => "route-deleted",
        "ts_ms" => DateTime.to_unix(~U[2026-06-23 09:00:30Z], :millisecond),
        "status" => "processing"
      },
      %{
        "route_id" => "route-1",
        "ts_ms" => DateTime.to_unix(~U[2026-06-23 09:00:30Z], :millisecond),
        "status" => "stopped"
      }
    ]

    assert [
             %{processing: 1, stopped: 0},
             %{processing: 0, stopped: 1}
           ] =
             Analytics.route_status_point_series(
               route_statuses,
               event_rows,
               from_dt,
               to_dt,
               bucket_ms,
               allowed_route_ids
             )
             |> Enum.map(fn point ->
               Map.take(point, [:processing, :stopped])
             end)
  end

  test "fetch_node_timeseries returns storage and database points and metadata" do
    :ok = Duckdb.ensure_schema()

    node_id = "storage-test-#{System.unique_integer([:positive])}"
    mountpoint = "/tmp/hydra-storage-test"
    storage_id = HydraSrt.Monitoring.OsMon.storage_id(mountpoint)
    ts = ~U[2026-06-16 12:00:00Z]

    storage_rows =
      [
        {"storage_total_bytes", 1000.0},
        {"storage_used_bytes", 400.0},
        {"storage_free_bytes", 600.0},
        {"storage_used_percent", 40.0}
      ]
      |> Enum.map(fn {metric_key, value} ->
        %{
          ts: ts,
          route_id: nil,
          entity_type: "storage",
          entity_id: "#{node_id}:#{mountpoint}",
          metric_key: metric_key,
          value_type: "double",
          value_double: value,
          value_bigint: nil,
          value_text: nil
        }
      end)

    database_rows = [
      %{
        ts: ts,
        route_id: nil,
        entity_type: "database",
        entity_id: "#{node_id}:metadata_database",
        metric_key: "database_size_bytes",
        value_type: "double",
        value_double: 2048.0,
        value_bigint: nil,
        value_text: nil
      }
    ]

    assert :ok = Duckdb.insert_rows(storage_rows ++ database_rows)

    assert {:ok, payload} =
             Analytics.fetch_node_timeseries(node_id, %{
               from: DateTime.add(ts, -60, :second),
               to: DateTime.add(ts, 60, :second),
               window: "custom",
               bucket_ms: 10_000
             })

    assert %{
             id: "metadata_database",
             mountpoint: "Metadata Database",
             name: "Metadata Database",
             type: "database"
           } in payload.meta.databases

    assert Enum.any?(payload.meta.storages, fn storage ->
             storage.id == storage_id and storage.mountpoint == mountpoint and
               storage.type == "mountpoint"
           end)

    assert %{id: "metadata_database", mountpoint: "Metadata Database", type: "database"} =
             Enum.find(payload.meta.storages, &(&1.id == "metadata_database"))

    assert payload.meta.default_storage_id == storage_id

    assert Enum.any?(payload.points, fn point ->
             point["storage_total_#{storage_id}"] == 1000.0 and
               point["storage_used_#{storage_id}"] == 400.0 and
               point["storage_free_#{storage_id}"] == 600.0 and
               point["storage_used_percent_#{storage_id}"] == 40.0
           end)

    assert Enum.any?(payload.points, fn point ->
             point["storage_total_metadata_database"] == 2048.0 and
               point["storage_used_metadata_database"] == 2048.0 and
               point["storage_free_metadata_database"] == 0.0 and
               point["storage_used_percent_metadata_database"] == 100.0
           end)
  end

  test "default_storage_id falls back without anchor paths" do
    rows = [
      %{
        entity_type: "storage",
        entity_id: "node@host:/",
        metric_key: "storage_total_bytes"
      }
    ]

    assert Analytics.default_storage_id(rows, []) == "root"
  end

  test "default_storage_id prefers mountpoint containing database paths" do
    rows = [
      %{
        entity_type: "storage",
        entity_id: "node@host:/",
        metric_key: "storage_total_bytes"
      },
      %{
        entity_type: "storage",
        entity_id: "node@host:/data",
        metric_key: "storage_total_bytes"
      }
    ]

    assert Analytics.default_storage_id(rows, ["/data/hydra_srt/hydra_srt.db"]) ==
             OsMon.storage_id("/data")
  end

  test "default_storage_id expands relative anchor paths before matching" do
    relative_db = "relative/hydra_srt.db"
    mountpoint = Path.dirname(Path.expand(relative_db))

    rows = [
      %{
        entity_type: "storage",
        entity_id: "node@host:/",
        metric_key: "storage_total_bytes"
      },
      %{
        entity_type: "storage",
        entity_id: "node@host:#{mountpoint}",
        metric_key: "storage_total_bytes"
      }
    ]

    assert Analytics.default_storage_id(rows, [relative_db]) == OsMon.storage_id(mountpoint)
  end

  test "source_timeline_from_switches builds contiguous segments" do
    query = %{to: ~U[2026-05-01 12:30:00Z]}

    switches = [
      %{"ts" => ~U[2026-05-01 12:00:00Z], "to_source_id" => "s1"},
      %{"ts" => ~U[2026-05-01 12:05:00Z], "to_source_id" => "s2"},
      %{"ts" => ~U[2026-05-01 12:10:00Z], "to_source_id" => "s2"},
      %{"ts" => ~U[2026-05-01 12:20:00Z], "to_source_id" => "s3"}
    ]

    assert [
             %{
               "from" => "2026-05-01T12:00:00Z",
               "to" => "2026-05-01T12:05:00Z",
               "source_id" => "s1"
             },
             %{
               "from" => "2026-05-01T12:05:00Z",
               "to" => "2026-05-01T12:20:00Z",
               "source_id" => "s2"
             },
             %{
               "from" => "2026-05-01T12:20:00Z",
               "to" => "2026-05-01T12:30:00Z",
               "source_id" => "s3"
             }
           ] = Analytics.source_timeline_from_switches(switches, query)
  end

  test "srt_health_points_from_rows maps legacy packet loss metric key" do
    rows = [
      %{
        timestamp: "2026-05-01T12:00:00Z",
        entity_type: "source",
        entity_id: "s1",
        metric_key: "srt_packet_loss",
        value: 0.25
      },
      %{
        timestamp: "2026-05-01T12:00:00Z",
        entity_type: "source",
        entity_id: "s1",
        metric_key: "srt_packet_loss_percent",
        value: 0.5
      }
    ]

    assert [point] = Analytics.srt_health_points_from_rows(rows)
    assert point.timestamp == "2026-05-01T12:00:00Z"
    assert point.entity_type == "source"
    assert point.entity_id == "s1"
    assert Map.get(point, "packet_loss_percent") == 0.5
  end
end

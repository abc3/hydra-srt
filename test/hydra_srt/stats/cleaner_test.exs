defmodule HydraSrt.Stats.CleanerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias HydraSrt.Stats.Cleaner
  alias HydraSrt.Stats.Duckdb

  setup do
    :ok = Duckdb.ensure_schema()
    :ok
  end

  test "log_pipeline_logs_cleanup_result is silent on success" do
    assert :ok = Cleaner.log_pipeline_logs_cleanup_result(:ok, 24)
  end

  test "log_pipeline_logs_cleanup_result logs pipeline_logs failures" do
    log =
      capture_log(fn ->
        assert :ok =
                 Cleaner.log_pipeline_logs_cleanup_result({:error, :db_down}, 12)
      end)

    assert log =~ "Stats cleaner failed for pipeline_logs"
    assert log =~ "retention_hours=12"
    assert log =~ "db_down"
  end

  test "delete_pipeline_logs_older_than removes stale rows" do
    route_id = "route-pl-cleaner-#{System.unique_integer([:positive])}"
    old_ts = DateTime.utc_now() |> DateTime.add(-48, :hour) |> DateTime.truncate(:second)
    recent_ts = DateTime.utc_now() |> DateTime.truncate(:second)

    assert :ok =
             Duckdb.insert_pipeline_logs([
               %{
                 ts: old_ts,
                 route_id: route_id,
                 level: "WARN",
                 category: "srt",
                 message: "old",
                 dropped_count: 0
               },
               %{
                 ts: recent_ts,
                 route_id: route_id,
                 level: "ERROR",
                 category: "srt",
                 message: "recent",
                 dropped_count: 0
               }
             ])

    assert :ok = Duckdb.delete_pipeline_logs_older_than(24)

    assert {:ok, messages} = fetch_messages(route_id)
    assert messages == ["recent"]
  end

  test "cleanup calls delete_pipeline_logs_older_than" do
    test_pid = self()

    :ok = :meck.new(Duckdb, [:passthrough])

    on_exit(fn ->
      try do
        :meck.unload(Duckdb)
      catch
        :error, {:not_mocked, _} -> :ok
      end
    end)

    :meck.expect(Duckdb, :delete_older_than, fn _hours -> :ok end)
    :meck.expect(Duckdb, :delete_events_older_than, fn _hours -> :ok end)

    :meck.expect(Duckdb, :delete_pipeline_logs_older_than, fn hours ->
      send(test_pid, {:delete_pipeline_logs, hours})
      :ok
    end)

    send(Cleaner, :cleanup)

    assert_receive {:delete_pipeline_logs, 24}, 500
  end

  defp fetch_messages(route_id) do
    sql = """
    SELECT message
    FROM pipeline_logs
    WHERE route_id = ?
    ORDER BY ts ASC
    """

    case Adbc.Connection.query(HydraSrt.AnalyticsConn, sql, [route_id]) do
      {:ok, result} ->
        messages = Map.get(Adbc.Result.to_map(result), "message", [])
        {:ok, messages}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

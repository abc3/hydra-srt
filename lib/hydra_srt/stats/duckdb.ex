defmodule HydraSrt.Stats.Duckdb do
  @moduledoc false

  require Logger

  @table "stats_samples"
  @events_table "events"

  @spec ensure_schema(GenServer.server()) :: :ok | {:error, term()}
  def ensure_schema(conn \\ HydraSrt.AnalyticsConn) do
    statements = [
      """
      CREATE TABLE IF NOT EXISTS stats_samples (
        ts TIMESTAMP,
        route_id VARCHAR,
        entity_type VARCHAR,
        entity_id VARCHAR,
        metric_key VARCHAR,
        value_type VARCHAR,
        value_double DOUBLE,
        value_bigint BIGINT,
        value_text VARCHAR
      )
      """,
      "CREATE INDEX IF NOT EXISTS idx_stats_samples_ts ON stats_samples(ts)",
      "CREATE INDEX IF NOT EXISTS idx_stats_samples_route_id ON stats_samples(route_id)",
      "CREATE INDEX IF NOT EXISTS idx_stats_samples_metric_key ON stats_samples(metric_key)",
      "CREATE INDEX IF NOT EXISTS idx_stats_samples_entity_id ON stats_samples(entity_id)",
      """
      CREATE TABLE IF NOT EXISTS events (
        ts TIMESTAMP,
        route_id VARCHAR,
        event_type VARCHAR,
        severity VARCHAR,
        source_id VARCHAR,
        from_source_id VARCHAR,
        to_source_id VARCHAR,
        reason VARCHAR,
        message VARCHAR,
        details_json VARCHAR
      )
      """,
      "CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts)",
      "CREATE INDEX IF NOT EXISTS idx_events_route_id ON events(route_id)",
      "CREATE INDEX IF NOT EXISTS idx_events_event_type ON events(event_type)",
      """
      CREATE TABLE IF NOT EXISTS pipeline_logs (
        ts TIMESTAMP,
        route_id VARCHAR,
        gst_ts VARCHAR,
        pid INTEGER,
        thread_id VARCHAR,
        level VARCHAR,
        category VARCHAR,
        element VARCHAR,
        file VARCHAR,
        line INTEGER,
        function VARCHAR,
        message VARCHAR,
        dropped_count INTEGER
      )
      """,
      "CREATE INDEX IF NOT EXISTS idx_pipeline_logs_ts ON pipeline_logs(ts)",
      "CREATE INDEX IF NOT EXISTS idx_pipeline_logs_route_id ON pipeline_logs(route_id)",
      "CREATE INDEX IF NOT EXISTS idx_pipeline_logs_level ON pipeline_logs(level)"
    ]

    Enum.reduce_while(statements, :ok, fn statement, :ok ->
      case execute(conn, statement) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec insert_rows([map()], GenServer.server()) :: :ok | {:error, term()}
  def insert_rows(rows, conn \\ HydraSrt.AnalyticsConn)
  def insert_rows([], _conn), do: :ok

  def insert_rows(rows, conn) when is_list(rows) do
    columns = to_columns(rows)

    case Adbc.Connection.bulk_insert(conn, columns, table: @table, mode: :append) do
      {:ok, _inserted_rows_count} ->
        :ok

      {:error, reason} ->
        Logger.error("Stats DuckDB insert failed reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec delete_older_than(pos_integer(), GenServer.server()) :: :ok | {:error, term()}
  def delete_older_than(hours, conn \\ HydraSrt.AnalyticsConn)
      when is_integer(hours) and hours > 0 do
    sql = "DELETE FROM stats_samples WHERE ts < (CURRENT_TIMESTAMP - INTERVAL '#{hours} HOURS')"
    execute(conn, sql)
  end

  @spec delete_events_older_than(pos_integer(), GenServer.server()) :: :ok | {:error, term()}
  def delete_events_older_than(hours, conn \\ HydraSrt.AnalyticsConn)
      when is_integer(hours) and hours > 0 do
    sql = "DELETE FROM events WHERE ts < (CURRENT_TIMESTAMP - INTERVAL '#{hours} HOURS')"
    execute(conn, sql)
  end

  @spec delete_pipeline_logs_older_than(pos_integer(), GenServer.server()) ::
          :ok | {:error, term()}
  def delete_pipeline_logs_older_than(hours, conn \\ HydraSrt.AnalyticsConn)
      when is_integer(hours) and hours > 0 do
    sql = "DELETE FROM pipeline_logs WHERE ts < (CURRENT_TIMESTAMP - INTERVAL '#{hours} HOURS')"
    execute(conn, sql)
  end

  @spec insert_pipeline_logs([map()], GenServer.server()) :: :ok | {:error, term()}
  def insert_pipeline_logs(rows, conn \\ HydraSrt.AnalyticsConn)
  def insert_pipeline_logs([], _conn), do: :ok

  def insert_pipeline_logs(rows, conn) when is_list(rows) do
    columns = to_pipeline_log_columns(rows)

    case Adbc.Connection.bulk_insert(conn, columns, table: "pipeline_logs", mode: :append) do
      {:ok, _inserted_rows_count} ->
        :ok

      {:error, reason} ->
        Logger.error("Stats DuckDB pipeline_logs insert failed reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec insert_events([map()], GenServer.server()) :: :ok | {:error, term()}
  def insert_events(rows, conn \\ HydraSrt.AnalyticsConn)
  def insert_events([], _conn), do: :ok

  def insert_events(rows, conn) when is_list(rows) do
    columns = to_event_columns(rows)

    case Adbc.Connection.bulk_insert(conn, columns, table: @events_table, mode: :append) do
      {:ok, _inserted_rows_count} ->
        :ok

      {:error, reason} ->
        Logger.error("Stats DuckDB events insert failed reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec execute(GenServer.server(), binary()) :: :ok | {:error, term()}
  def execute(conn, sql) when is_binary(sql) do
    case Adbc.Connection.execute(conn, sql) do
      {:ok, _rows_affected} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec to_columns([map()]) :: [Adbc.Column.t()]
  def to_columns(rows) when is_list(rows) do
    ts_values = Enum.map(rows, &normalize_ts/1)
    route_id_values = Enum.map(rows, &Map.get(&1, :route_id))
    entity_type_values = Enum.map(rows, &Map.get(&1, :entity_type))
    entity_id_values = Enum.map(rows, &Map.get(&1, :entity_id))
    metric_key_values = Enum.map(rows, &Map.get(&1, :metric_key))
    value_type_values = Enum.map(rows, &Map.get(&1, :value_type))
    value_double_values = Enum.map(rows, &Map.get(&1, :value_double))
    value_bigint_values = Enum.map(rows, &Map.get(&1, :value_bigint))
    value_text_values = Enum.map(rows, &Map.get(&1, :value_text))

    [
      Adbc.Column.timestamp(ts_values, :microseconds, "UTC", name: "ts"),
      Adbc.Column.string(route_id_values, name: "route_id"),
      Adbc.Column.string(entity_type_values, name: "entity_type"),
      Adbc.Column.string(entity_id_values, name: "entity_id"),
      Adbc.Column.string(metric_key_values, name: "metric_key"),
      Adbc.Column.string(value_type_values, name: "value_type"),
      Adbc.Column.f64(value_double_values, name: "value_double"),
      Adbc.Column.s64(value_bigint_values, name: "value_bigint"),
      Adbc.Column.string(value_text_values, name: "value_text")
    ]
  end

  @spec to_event_columns([map()]) :: [Adbc.Column.t()]
  def to_event_columns(rows) when is_list(rows) do
    ts_values = Enum.map(rows, &normalize_ts/1)

    [
      Adbc.Column.timestamp(ts_values, :microseconds, "UTC", name: "ts"),
      Adbc.Column.string(Enum.map(rows, &Map.get(&1, :route_id)), name: "route_id"),
      Adbc.Column.string(Enum.map(rows, &Map.get(&1, :event_type)), name: "event_type"),
      Adbc.Column.string(Enum.map(rows, &Map.get(&1, :severity)), name: "severity"),
      Adbc.Column.string(Enum.map(rows, &Map.get(&1, :source_id)), name: "source_id"),
      Adbc.Column.string(Enum.map(rows, &Map.get(&1, :from_source_id)), name: "from_source_id"),
      Adbc.Column.string(Enum.map(rows, &Map.get(&1, :to_source_id)), name: "to_source_id"),
      Adbc.Column.string(Enum.map(rows, &Map.get(&1, :reason)), name: "reason"),
      Adbc.Column.string(Enum.map(rows, &Map.get(&1, :message)), name: "message"),
      Adbc.Column.string(Enum.map(rows, &Map.get(&1, :details_json)), name: "details_json")
    ]
  end

  @spec to_pipeline_log_columns([map()]) :: [Adbc.Column.t()]
  def to_pipeline_log_columns(rows) when is_list(rows) do
    [
      Adbc.Column.timestamp(Enum.map(rows, &normalize_ts/1), :microseconds, "UTC", name: "ts"),
      Adbc.Column.string(Enum.map(rows, &Map.get(&1, :route_id)), name: "route_id"),
      Adbc.Column.string(Enum.map(rows, &Map.get(&1, :gst_ts)), name: "gst_ts"),
      Adbc.Column.s64(Enum.map(rows, &Map.get(&1, :pid)), name: "pid"),
      Adbc.Column.string(Enum.map(rows, &Map.get(&1, :thread_id)), name: "thread_id"),
      Adbc.Column.string(Enum.map(rows, &Map.get(&1, :level)), name: "level"),
      Adbc.Column.string(Enum.map(rows, &Map.get(&1, :category)), name: "category"),
      Adbc.Column.string(Enum.map(rows, &Map.get(&1, :element)), name: "element"),
      Adbc.Column.string(Enum.map(rows, &Map.get(&1, :file)), name: "file"),
      Adbc.Column.s64(Enum.map(rows, &Map.get(&1, :line)), name: "line"),
      Adbc.Column.string(Enum.map(rows, &Map.get(&1, :function)), name: "function"),
      Adbc.Column.string(Enum.map(rows, &Map.get(&1, :message)), name: "message"),
      Adbc.Column.s64(Enum.map(rows, &(Map.get(&1, :dropped_count) || 0)), name: "dropped_count")
    ]
  end

  @spec normalize_ts(map()) :: NaiveDateTime.t()
  def normalize_ts(row) when is_map(row) do
    case Map.get(row, :ts) do
      %NaiveDateTime{} = ts ->
        ts

      %DateTime{} = ts ->
        DateTime.to_naive(ts)

      _ ->
        DateTime.utc_now() |> DateTime.to_naive()
    end
  end
end

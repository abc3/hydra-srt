defmodule HydraSrt.Stats.Collector do
  @moduledoc false
  use GenServer
  require Logger

  alias HydraSrt.Stats.Duckdb
  alias HydraSrt.Stats.MetricSelector

  @default_flush_interval_ms 15_000
  @default_max_batch_size 10_000
  @default_downsample_interval_ms 10_000

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(opts \\ %{}) when is_map(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec ingest(binary(), map()) :: :ok
  def ingest(route_id, stats) when is_binary(route_id) and is_map(stats) do
    send(__MODULE__, {:ingest_route_stats, route_id, stats})
    :ok
  end

  @impl true
  def init(opts) when is_map(opts) do
    flush_interval_ms = opts[:flush_interval_ms] || @default_flush_interval_ms
    max_batch_size = opts[:max_batch_size] || @default_max_batch_size
    downsample_interval_ms = opts[:downsample_interval_ms] || @default_downsample_interval_ms

    case Duckdb.ensure_schema() do
      :ok ->
        schedule_flush(flush_interval_ms)

        {:ok,
         %{
           rows_by_bucket_and_series: %{},
           row_count: 0,
           flush_interval_ms: flush_interval_ms,
           max_batch_size: max_batch_size,
           downsample_interval_ms: downsample_interval_ms
         }}

      {:error, reason} ->
        {:stop, {:duckdb_schema_bootstrap_failed, reason}}
    end
  end

  @impl true
  def handle_info({:ingest_route_stats, route_id, stats}, state)
      when is_binary(route_id) and is_map(stats) do
    envelope = %{
      route_id: route_id,
      stats: stats,
      ts: DateTime.utc_now()
    }

    selected_rows = MetricSelector.select_rows(envelope)

    rows_by_bucket_and_series =
      merge_rows(
        state.rows_by_bucket_and_series,
        selected_rows,
        state.downsample_interval_ms
      )

    row_count = map_size(rows_by_bucket_and_series)

    if row_count >= state.max_batch_size do
      {rows_after_flush, row_count_after_flush, flush_result} =
        flush_rows(rows_by_bucket_and_series, row_count)

      log_flush_error(flush_result)

      {:noreply,
       %{state | rows_by_bucket_and_series: rows_after_flush, row_count: row_count_after_flush}}
    else
      {:noreply,
       %{state | rows_by_bucket_and_series: rows_by_bucket_and_series, row_count: row_count}}
    end
  end

  def handle_info(:flush, state) do
    {rows_after_flush, row_count_after_flush, flush_result} =
      flush_rows(state.rows_by_bucket_and_series, state.row_count)

    log_flush_error(flush_result)
    schedule_flush(state.flush_interval_ms)

    {:noreply,
     %{state | rows_by_bucket_and_series: rows_after_flush, row_count: row_count_after_flush}}
  end

  @impl true
  def terminate(_reason, state) do
    {_rows_after_flush, _row_count_after_flush, flush_result} =
      flush_rows(state.rows_by_bucket_and_series, state.row_count)

    log_flush_error(flush_result)
    :ok
  end

  @spec schedule_flush(pos_integer()) :: reference()
  def schedule_flush(flush_interval_ms)
      when is_integer(flush_interval_ms) and flush_interval_ms > 0 do
    Process.send_after(self(), :flush, flush_interval_ms)
  end

  @spec merge_rows(map(), [map()], pos_integer()) :: map()
  def merge_rows(rows_by_bucket_and_series, rows, downsample_interval_ms)
      when is_map(rows_by_bucket_and_series) and is_list(rows) and
             is_integer(downsample_interval_ms) and downsample_interval_ms > 0 do
    Enum.reduce(rows, rows_by_bucket_and_series, fn row, acc ->
      key = row_bucket_and_series_key(row, downsample_interval_ms)
      Map.put(acc, key, row)
    end)
  end

  @spec row_bucket_and_series_key(map(), pos_integer()) :: tuple()
  def row_bucket_and_series_key(row, downsample_interval_ms)
      when is_map(row) and is_integer(downsample_interval_ms) and downsample_interval_ms > 0 do
    {
      row_bucket_start_ms(row, downsample_interval_ms),
      row_series_key(row)
    }
  end

  @spec row_bucket_start_ms(map(), pos_integer()) :: non_neg_integer()
  def row_bucket_start_ms(row, downsample_interval_ms)
      when is_map(row) and is_integer(downsample_interval_ms) and downsample_interval_ms > 0 do
    ts_unix_ms = row_ts_unix_ms(row)
    div(ts_unix_ms, downsample_interval_ms) * downsample_interval_ms
  end

  @spec row_series_key(map()) :: tuple()
  def row_series_key(row) when is_map(row) do
    {
      Map.get(row, :route_id),
      Map.get(row, :entity_type),
      Map.get(row, :entity_id),
      Map.get(row, :metric_key),
      Map.get(row, :value_type)
    }
  end

  @spec row_ts_unix_ms(map()) :: non_neg_integer()
  def row_ts_unix_ms(row) when is_map(row) do
    case Map.get(row, :ts) do
      %DateTime{} = ts ->
        DateTime.to_unix(ts, :millisecond)

      %NaiveDateTime{} = ts ->
        ts |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)

      _ ->
        DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    end
  end

  @spec flush_rows(map(), non_neg_integer(), ([map()] -> :ok | {:error, term()})) ::
          {map(), non_neg_integer(), :ok | {:error, term()}}
  def flush_rows(rows_by_bucket_and_series, row_count, insert_rows_fun \\ &Duckdb.insert_rows/1)

  def flush_rows(rows_by_bucket_and_series, 0, _insert_rows_fun)
      when is_map(rows_by_bucket_and_series) and map_size(rows_by_bucket_and_series) == 0 do
    {%{}, 0, :ok}
  end

  def flush_rows(rows_by_bucket_and_series, row_count, insert_rows_fun)
      when is_map(rows_by_bucket_and_series) and is_integer(row_count) and row_count >= 0 and
             is_function(insert_rows_fun, 1) do
    rows =
      rows_by_bucket_and_series
      |> Map.values()
      |> Enum.sort_by(fn row ->
        {
          row_ts_unix_ms(row),
          Map.get(row, :route_id),
          Map.get(row, :entity_type),
          Map.get(row, :entity_id),
          Map.get(row, :metric_key)
        }
      end)

    case insert_rows_fun.(rows) do
      :ok -> {%{}, 0, :ok}
      {:error, reason} -> {rows_by_bucket_and_series, row_count, {:error, reason}}
    end
  end

  @spec log_flush_error(:ok | {:error, term()}) :: :ok
  def log_flush_error(:ok), do: :ok

  def log_flush_error({:error, reason}) do
    Logger.error("Stats collector flush failed reason=#{inspect(reason)}")
    :ok
  end
end

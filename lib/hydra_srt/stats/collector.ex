defmodule HydraSrt.Stats.Collector do
  @moduledoc false
  use GenServer
  require Logger

  alias HydraSrt.Stats.Duckdb
  alias HydraSrt.Stats.MetricSelector

  @default_flush_interval_ms 15_000
  @default_max_batch_size 10_000

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

    case Duckdb.ensure_schema() do
      :ok ->
        schedule_flush(flush_interval_ms)

        {:ok,
         %{
           rows_rev: [],
           row_count: 0,
           flush_interval_ms: flush_interval_ms,
           max_batch_size: max_batch_size
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
    selected_rows_count = length(selected_rows)
    rows_rev = selected_rows ++ state.rows_rev
    row_count = state.row_count + selected_rows_count

    if row_count >= state.max_batch_size do
      {rows_after_flush, row_count_after_flush, flush_result} = flush_rows(rows_rev, row_count)
      log_flush_error(flush_result)
      {:noreply, %{state | rows_rev: rows_after_flush, row_count: row_count_after_flush}}
    else
      {:noreply, %{state | rows_rev: rows_rev, row_count: row_count}}
    end
  end

  def handle_info(:flush, state) do
    {rows_after_flush, row_count_after_flush, flush_result} =
      flush_rows(state.rows_rev, state.row_count)

    log_flush_error(flush_result)
    schedule_flush(state.flush_interval_ms)
    {:noreply, %{state | rows_rev: rows_after_flush, row_count: row_count_after_flush}}
  end

  @impl true
  def terminate(_reason, state) do
    {_rows_after_flush, _row_count_after_flush, flush_result} =
      flush_rows(state.rows_rev, state.row_count)

    log_flush_error(flush_result)
    :ok
  end

  @spec schedule_flush(pos_integer()) :: reference()
  def schedule_flush(flush_interval_ms)
      when is_integer(flush_interval_ms) and flush_interval_ms > 0 do
    Process.send_after(self(), :flush, flush_interval_ms)
  end

  @spec flush_rows([map()], non_neg_integer()) ::
          {[map()], non_neg_integer(), :ok | {:error, term()}}
  def flush_rows([], 0), do: {[], 0, :ok}

  def flush_rows(rows_rev, row_count)
      when is_list(rows_rev) and is_integer(row_count) and row_count >= 0 do
    rows = Enum.reverse(rows_rev)

    case Duckdb.insert_rows(rows) do
      :ok -> {[], 0, :ok}
      {:error, reason} -> {rows_rev, row_count, {:error, reason}}
    end
  end

  @spec log_flush_error(:ok | {:error, term()}) :: :ok
  def log_flush_error(:ok), do: :ok

  def log_flush_error({:error, reason}) do
    Logger.error("Stats collector flush failed reason=#{inspect(reason)}")
    :ok
  end
end

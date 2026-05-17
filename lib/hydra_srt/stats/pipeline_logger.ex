defmodule HydraSrt.Stats.PipelineLogger do
  @moduledoc false
  use GenServer
  require Logger

  alias HydraSrt.PipelineLogTelemetry
  alias HydraSrt.Stats.Duckdb

  @default_flush_interval_ms 5_000
  @default_max_verbose_per_window 200
  @verbose_levels ~w(INFO DEBUG FIXME LOG TRACE)

  def start_link(opts \\ %{}) when is_map(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) when is_map(opts) do
    flush_interval_ms = Map.get(opts, :flush_interval_ms, @default_flush_interval_ms)

    max_verbose_per_window =
      Map.get(opts, :max_verbose_per_window, @default_max_verbose_per_window)

    :ok = Phoenix.PubSub.subscribe(HydraSrt.PubSub, "pipeline_logs")

    schedule_flush(flush_interval_ms)

    {:ok,
     %{
       logs: [],
       rate_counters: %{},
       flush_interval_ms: flush_interval_ms,
       max_verbose_per_window: max_verbose_per_window
     }}
  end

  @impl true
  def handle_info({:pipeline_log, log}, state) do
    {logs, rate_counters} =
      maybe_buffer(log, state.logs, state.rate_counters, state.max_verbose_per_window)

    {:noreply, %{state | logs: logs, rate_counters: rate_counters}}
  end

  def handle_info(:flush, state) do
    {logs, rate_counters} = flush_logs(state.logs, state.rate_counters)
    schedule_flush(state.flush_interval_ms)
    {:noreply, %{state | logs: logs, rate_counters: rate_counters}}
  end

  @impl true
  def terminate(_reason, state) do
    {logs, rate_counters} = build_synthetic_dropped_records(state.logs, state.rate_counters)
    Duckdb.insert_pipeline_logs(Enum.reverse(logs))
    _ = rate_counters
    :ok
  end

  def schedule_flush(flush_interval_ms)
      when is_integer(flush_interval_ms) and flush_interval_ms > 0 do
    Process.send_after(self(), :flush, flush_interval_ms)
  end

  @spec flush_logs([map()], map(), (list() -> :ok | {:error, term()})) :: {[map()], map()}
  def flush_logs(logs, rate_counters \\ %{}, insert_fun \\ &Duckdb.insert_pipeline_logs/1)

  def flush_logs(logs, rate_counters, insert_fun)
      when is_list(logs) and is_map(rate_counters) and is_function(insert_fun, 1) do
    {merged_logs, _rate_counters} = build_synthetic_dropped_records(logs, rate_counters)
    rows = Enum.reverse(merged_logs)

    case insert_fun.(rows) do
      :ok ->
        {[], %{}}

      {:error, reason} ->
        Logger.error("PipelineLogger flush failed reason=#{inspect(reason)}")
        {merged_logs, %{}}
    end
  end

  defp maybe_buffer(log, logs, rate_counters, max_verbose_per_window) do
    if log.level in @verbose_levels do
      route_id = log.route_id
      counter = Map.get(rate_counters, route_id, %{count: 0, dropped: 0})

      if counter.count >= max_verbose_per_window do
        :ok = PipelineLogTelemetry.emit_dropped(route_id, log.level)
        updated = %{counter | dropped: counter.dropped + 1}
        {logs, Map.put(rate_counters, route_id, updated)}
      else
        :ok = PipelineLogTelemetry.emit_stored(route_id, log.level)
        updated = %{counter | count: counter.count + 1}
        {[enrich(log) | logs], Map.put(rate_counters, route_id, updated)}
      end
    else
      :ok = PipelineLogTelemetry.emit_stored(log.route_id, log.level)
      {[enrich(log) | logs], rate_counters}
    end
  end

  defp build_synthetic_dropped_records(logs, rate_counters) do
    synthetic =
      rate_counters
      |> Enum.filter(fn {_route_id, %{dropped: d}} -> d > 0 end)
      |> Enum.map(fn {route_id, %{dropped: dropped}} ->
        :ok = PipelineLogTelemetry.emit_stored(route_id, "WARN")

        enrich(%{
          route_id: route_id,
          gst_ts: nil,
          pid: nil,
          thread_id: nil,
          level: "WARN",
          category: "pipeline_logger",
          file: nil,
          line: nil,
          function: nil,
          element: nil,
          message: "rate limited: dropped #{dropped} lines",
          dropped_count: dropped
        })
      end)

    {synthetic ++ logs, rate_counters}
  end

  defp enrich(log) do
    Map.merge(
      %{
        ts: DateTime.utc_now(),
        route_id: nil,
        gst_ts: nil,
        pid: nil,
        thread_id: nil,
        level: nil,
        category: nil,
        element: nil,
        file: nil,
        line: nil,
        function: nil,
        message: nil,
        dropped_count: 0
      },
      log
    )
  end
end

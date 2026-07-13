defmodule HydraSrt.Stats.PipelineLogger do
  @moduledoc false
  use GenServer
  require Logger

  alias HydraSrt.PipelineLogTelemetry
  alias HydraSrt.Stats.VictoriaLogs

  @default_flush_interval_ms 5_000
  @default_max_verbose_per_window 200
  @default_max_buffer_size 20_000
  @verbose_levels ~w(INFO DEBUG FIXME LOG TRACE)

  def start_link(opts \\ %{}) when is_map(opts) do
    name = Map.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def noop_insert(_rows), do: :ok

  @impl true
  def init(opts) when is_map(opts) do
    flush_interval_ms = Map.get(opts, :flush_interval_ms, @default_flush_interval_ms)

    max_verbose_per_window =
      Map.get(opts, :max_verbose_per_window, @default_max_verbose_per_window)

    max_buffer_size = Map.get(opts, :max_buffer_size, @default_max_buffer_size)
    insert_logs_fun = resolve_insert_logs_fun(Map.get(opts, :insert_logs_fun))

    :ok = Phoenix.PubSub.subscribe(HydraSrt.PubSub, "pipeline_logs")

    schedule_flush(flush_interval_ms)

    {:ok,
     %{
       logs: [],
       rate_counters: %{},
       flush_interval_ms: flush_interval_ms,
       max_verbose_per_window: max_verbose_per_window,
       max_buffer_size: max_buffer_size,
       insert_logs_fun: insert_logs_fun
     }}
  end

  @impl true
  def handle_info({:pipeline_log, log}, state) do
    {logs, rate_counters} =
      maybe_buffer(log, state.logs, state.rate_counters, state.max_verbose_per_window)

    logs = enforce_max_buffer(logs, state.max_buffer_size)

    {:noreply, %{state | logs: logs, rate_counters: rate_counters}}
  end

  def handle_info(:flush, state) do
    {logs, rate_counters} =
      flush_logs(state.logs, state.rate_counters, state.insert_logs_fun, state.max_buffer_size)

    schedule_flush(state.flush_interval_ms)
    {:noreply, %{state | logs: logs, rate_counters: rate_counters}}
  end

  @impl true
  def terminate(_reason, state) do
    {logs, rate_counters} = build_synthetic_dropped_records(state.logs, state.rate_counters)
    state.insert_logs_fun.(Enum.reverse(logs))
    _ = rate_counters
    :ok
  end

  def schedule_flush(flush_interval_ms)
      when is_integer(flush_interval_ms) and flush_interval_ms > 0 do
    Process.send_after(self(), :flush, flush_interval_ms)
  end

  @spec flush_logs([map()], map(), (list() -> :ok | {:error, term()}), pos_integer() | nil) ::
          {[map()], map()}
  def flush_logs(
        logs,
        rate_counters \\ %{},
        insert_fun \\ &VictoriaLogs.insert_pipeline_logs/1,
        max_buffer_size \\ nil
      )

  def flush_logs(logs, rate_counters, insert_fun, max_buffer_size)
      when is_list(logs) and is_map(rate_counters) and is_function(insert_fun, 1) do
    {merged_logs, _rate_counters} = build_synthetic_dropped_records(logs, rate_counters)
    rows = Enum.reverse(merged_logs)

    case insert_fun.(rows) do
      :ok ->
        {[], %{}}

      {:error, reason} ->
        Logger.error("PipelineLogger flush failed reason=#{inspect(reason)}")
        {enforce_max_buffer(merged_logs, max_buffer_size), %{}}
    end
  end

  def enforce_max_buffer(logs, max_buffer_size)
      when is_list(logs) and is_integer(max_buffer_size) and max_buffer_size > 0 and
             length(logs) > max_buffer_size do
    dropped = length(logs) - max_buffer_size

    Logger.warning("Pipeline logger dropped #{dropped} buffered log lines due to max_buffer_size")

    Enum.take(logs, max_buffer_size)
  end

  def enforce_max_buffer(logs, _max_buffer_size) when is_list(logs), do: logs

  def resolve_insert_logs_fun(fun) when is_function(fun, 1), do: fun

  def resolve_insert_logs_fun({module, function, args})
      when is_atom(module) and is_atom(function) and is_list(args) do
    fn rows -> apply(module, function, [rows | args]) end
  end

  def resolve_insert_logs_fun(_), do: &VictoriaLogs.insert_pipeline_logs/1

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

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

  # Upper bound on how many distinct WARN/ERROR signatures a single route is
  # allowed to remember at once. A route in a hard reconnect loop realistically
  # cycles through a small, fixed vocabulary of message shapes (a bus error, a
  # reconnect notice, a stats-read failure, ...); this cap is generous headroom
  # above that while still bounding memory against a route whose native process
  # is somehow producing an unbounded variety of distinct WARN/ERROR text.
  @max_dedup_signatures_per_route 32

  # GStreamer's SRT stats-polling failure warning embeds the OS socket handle
  # ("failed to retrieve stats for socket 47 (...)"), which is a new number on
  # essentially every reconnect attempt even though the underlying condition -
  # "could not read stats for a socket that just disappeared" - has not
  # changed at all. Masking *only* this specific volatile
  # token (not every digit in a message, which would risk collapsing two
  # genuinely different states - e.g. two different SRT error codes in
  # "Connection timeout (16)" vs some other "(NN)" - into the same signature)
  # is what lets this exact repeat be recognised as a repeat at all: compared
  # byte-for-byte, every occurrence looks like a brand new message.
  @volatile_socket_id_pattern ~r/\bsocket \d+\b/

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
    _ = state.insert_logs_fun.(Enum.reverse(logs))
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
    {merged_logs, rate_counters} = build_synthetic_dropped_records(logs, rate_counters)
    rows = Enum.reverse(merged_logs)

    case insert_fun.(rows) do
      :ok ->
        {[], reset_counters_after_flush(rate_counters)}

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

  @spec fresh_counter() :: map()
  defp fresh_counter,
    do: %{count: 0, dropped: 0, dedup: %{}}

  # Two independent throttles share one per-route counter:
  #
  #   * verbose levels (INFO/DEBUG/...) are capped at `max_verbose_per_window`
  #     total lines per flush window (`count`/`dropped`) - unchanged.
  #   * non-verbose levels (WARN/ERROR/...) are deduplicated by normalized
  #     content, with one independent slot per distinct signature (`dedup`,
  #     a `%{signature => %{dropped: n, sample: log}}` map, bounded by
  #     `@max_dedup_signatures_per_route`): the first occurrence of a
  #     signature always passes through; an identical repeat under that same
  #     signature is suppressed and counted, never silently discarded - it
  #     surfaces later as a synthetic row via `build_synthetic_dropped_records/2`.
  #     Giving every signature its own slot (instead of one shared slot for
  #     the whole route) is what makes this robust to interleaving: SRT's
  #     dead-port failure mode alternates two distinct recurring WARN shapes
  #     every reconnect cycle, and a single shared slot got stomped by the
  #     other message before either one's repeat could be recognised,
  #     defeating the dedup entirely for that traffic pattern.
  defp maybe_buffer(log, logs, rate_counters, max_verbose_per_window) do
    route_id = log.route_id
    counter = Map.get(rate_counters, route_id, fresh_counter())

    if log.level in @verbose_levels do
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
      signature = dedup_signature(log)

      case Map.get(counter.dedup, signature) do
        nil ->
          :ok = PipelineLogTelemetry.emit_stored(route_id, log.level)

          {dedup, evicted_rows} = admit_dedup_signature(counter.dedup, route_id, signature, log)
          updated = %{counter | dedup: dedup}
          {evicted_rows ++ [enrich(log) | logs], Map.put(rate_counters, route_id, updated)}

        entry ->
          :ok = PipelineLogTelemetry.emit_dropped(route_id, log.level)

          updated_dedup = Map.put(counter.dedup, signature, %{entry | dropped: entry.dropped + 1})
          updated = %{counter | dedup: updated_dedup}
          {logs, Map.put(rate_counters, route_id, updated)}
      end
    end
  end

  # The exact signature a WARN/ERROR is deduplicated under: level, category,
  # element, and the message with only its known-volatile parts normalized
  # away (see `@volatile_socket_id_pattern`) - not the raw message, which
  # would defeat dedup for a repeating message that happens to embed a
  # changing resource handle, and not every digit, which would risk
  # collapsing two genuinely different states into one signature.
  @spec dedup_signature(map()) :: tuple()
  defp dedup_signature(log) do
    normalized_message = Regex.replace(@volatile_socket_id_pattern, log.message, "socket <id>")
    {log.level, Map.get(log, :category), Map.get(log, :element), normalized_message}
  end

  # Admits a brand new signature into the per-route dedup table. When the
  # table is already at capacity, evicts the coldest entry (fewest currently
  # suppressed repeats) to make room - after materializing its own pending
  # tally as a synthetic row first, so bounding memory never silently loses a
  # count.
  @spec admit_dedup_signature(map(), String.t(), tuple(), map()) :: {map(), [map()]}
  defp admit_dedup_signature(dedup, _route_id, signature, log)
       when map_size(dedup) < @max_dedup_signatures_per_route do
    {Map.put(dedup, signature, %{dropped: 0, sample: log}), []}
  end

  defp admit_dedup_signature(dedup, route_id, signature, log) do
    {evicted_signature, evicted_entry} = Enum.min_by(dedup, fn {_sig, entry} -> entry.dropped end)

    dedup =
      dedup
      |> Map.delete(evicted_signature)
      |> Map.put(signature, %{dropped: 0, sample: log})

    evicted_rows =
      if evicted_entry.dropped > 0 do
        [synthetic_dedup_row(route_id, evicted_entry.sample, evicted_entry.dropped)]
      else
        []
      end

    {dedup, evicted_rows}
  end

  defp build_synthetic_dropped_records(logs, rate_counters) do
    verbose_synthetic =
      rate_counters
      |> Enum.filter(fn {_route_id, counter} -> Map.get(counter, :dropped, 0) > 0 end)
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

    dedup_synthetic =
      rate_counters
      |> Enum.flat_map(fn {route_id, counter} ->
        counter
        |> Map.get(:dedup, %{})
        |> Enum.filter(fn {_signature, entry} -> entry.dropped > 0 end)
        |> Enum.map(fn {_signature, entry} ->
          synthetic_dedup_row(route_id, entry.sample, entry.dropped)
        end)
      end)

    {dedup_synthetic ++ verbose_synthetic ++ logs, rate_counters}
  end

  defp synthetic_dedup_row(route_id, sample, dropped) when dropped > 0 do
    :ok = PipelineLogTelemetry.emit_stored(route_id, "WARN")

    repeated_message = if is_map(sample), do: sample.message, else: nil

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
      message: "suppressed #{dropped} duplicate log lines: #{repeated_message}",
      dropped_count: dropped
    })
  end

  # Verbose overflow (`count`/`dropped`) is strictly per flush window and
  # always resets. Each dedup signature's own `sample` and identity survive a
  # successful flush so an unchanged repeated WARN/ERROR keeps being
  # suppressed across windows instead of getting re-admitted every tick; each
  # signature's `dropped` still resets since any accumulated count was just
  # materialized into a synthetic row above. Routes with nothing left to
  # remember (empty dedup table) are dropped entirely, which keeps this
  # compatible with callers that expect a plain `%{}` after a quiet flush.
  defp reset_counters_after_flush(rate_counters) do
    rate_counters
    |> Enum.map(fn {route_id, counter} ->
      reset_dedup =
        counter
        |> Map.get(:dedup, %{})
        |> Map.new(fn {signature, entry} -> {signature, %{entry | dropped: 0}} end)

      {route_id, Map.merge(counter, %{count: 0, dropped: 0, dedup: reset_dedup})}
    end)
    |> Enum.reject(fn {_route_id, counter} -> map_size(Map.get(counter, :dedup, %{})) == 0 end)
    |> Map.new()
  end

  defp enrich(log) do
    defaults = %{
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
      dropped_count: 0,
      sequence: nil,
      observed_at_ms: nil
    }

    merged = Map.merge(defaults, log)

    case Map.get(log, :observed_at_ms) do
      ms when is_integer(ms) -> %{merged | ts: DateTime.from_unix!(ms, :millisecond)}
      _ -> merged
    end
  end
end

defmodule HydraSrt.Stats.EventLogger do
  @moduledoc false
  use GenServer
  require Logger

  alias HydraSrt.Stats.Duckdb

  @default_flush_interval_ms 5_000
  @default_max_batch_size 1_000

  def start_link(opts \\ %{}) when is_map(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def log_source_switch(route_id, from_source_id, to_source_id, reason, details \\ %{}) do
    severity =
      case reason do
        "manual" -> "info"
        "primary_recovered" -> "info"
        _ -> "warning"
      end

    ingest(%{
      route_id: route_id,
      event_type: "source_switch",
      severity: severity,
      source_id: to_source_id,
      from_source_id: from_source_id,
      to_source_id: to_source_id,
      reason: reason,
      message: "Source switched",
      details_json: Jason.encode!(details || %{})
    })
  end

  def log_pipeline_failed(route_id, source_id, reason, message) do
    ingest(%{
      route_id: route_id,
      event_type: "pipeline_failed",
      severity: "error",
      source_id: source_id,
      reason: reason,
      message: message
    })
  end

  def log_pipeline_reconnecting(route_id, source_id) do
    ingest(%{
      route_id: route_id,
      event_type: "pipeline_reconnecting",
      severity: "warning",
      source_id: source_id,
      message: "Pipeline reconnecting"
    })
  end

  def log_source_probe_failed(route_id, source_id, error) do
    ingest(%{
      route_id: route_id,
      event_type: "source_probe_failed",
      severity: "warning",
      source_id: source_id,
      message: to_string(error)
    })
  end

  def log_source_status_change(route_id, source_id, old_status, new_status) do
    ingest(%{
      route_id: route_id,
      event_type: "source_status_change",
      severity: "info",
      source_id: source_id,
      message: "Source status changed",
      details_json: Jason.encode!(%{"old_status" => old_status, "new_status" => new_status})
    })
  end

  def ingest(event) when is_map(event) do
    enriched = enrich(event)
    broadcast_event(enriched)

    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:ingest_event, enriched})
    end

    :ok
  end

  def broadcast_event(event) when is_map(event) do
    route_id = Map.get(event, :route_id) || Map.get(event, "route_id")

    if is_binary(route_id) and route_id != "" do
      Phoenix.PubSub.broadcast(
        HydraSrt.PubSub,
        "events:" <> route_id,
        {:event, event_to_payload(event)}
      )
    end

    :ok
  end

  @impl true
  def init(opts) when is_map(opts) do
    flush_interval_ms = opts[:flush_interval_ms] || @default_flush_interval_ms
    max_batch_size = opts[:max_batch_size] || @default_max_batch_size
    schedule_flush(flush_interval_ms)

    {:ok, %{events: [], flush_interval_ms: flush_interval_ms, max_batch_size: max_batch_size}}
  end

  @impl true
  def handle_info({:ingest_event, event}, state) do
    events = [event | state.events]

    if length(events) >= state.max_batch_size do
      {events_after_flush, result} = flush_events(events)
      log_flush_error(result)
      {:noreply, %{state | events: events_after_flush}}
    else
      {:noreply, %{state | events: events}}
    end
  end

  def handle_info(:flush, state) do
    {events_after_flush, result} = flush_events(state.events)
    log_flush_error(result)
    schedule_flush(state.flush_interval_ms)
    {:noreply, %{state | events: events_after_flush}}
  end

  @impl true
  def handle_cast({:ingest_event, event}, state) do
    events = [event | state.events]

    if length(events) >= state.max_batch_size do
      {events_after_flush, result} = flush_events(events)
      log_flush_error(result)
      {:noreply, %{state | events: events_after_flush}}
    else
      {:noreply, %{state | events: events}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    {_events, result} = flush_events(state.events)
    log_flush_error(result)
    :ok
  end

  def flush_events(events, insert_fun \\ &Duckdb.insert_events/1)
  def flush_events([], _insert_fun), do: {[], :ok}

  def flush_events(events, insert_fun) when is_list(events) and is_function(insert_fun, 1) do
    rows = Enum.reverse(events)

    case insert_fun.(rows) do
      :ok -> {[], :ok}
      {:error, reason} -> {events, {:error, reason}}
    end
  end

  def schedule_flush(flush_interval_ms)
      when is_integer(flush_interval_ms) and flush_interval_ms > 0 do
    Process.send_after(self(), :flush, flush_interval_ms)
  end

  defp enrich(event) do
    Map.merge(
      %{
        ts: DateTime.utc_now(),
        route_id: nil,
        event_type: "unknown",
        severity: "info",
        source_id: nil,
        from_source_id: nil,
        to_source_id: nil,
        reason: nil,
        message: nil,
        details_json: nil
      },
      event
    )
  end

  defp log_flush_error(:ok), do: :ok

  defp log_flush_error({:error, reason}) do
    Logger.error("Event logger flush failed reason=#{inspect(reason)}")
    :ok
  end

  defp event_to_payload(event) do
    %{
      "ts" => event |> Map.get(:ts) |> normalize_ts(),
      "route_id" => Map.get(event, :route_id),
      "event_type" => Map.get(event, :event_type),
      "severity" => Map.get(event, :severity),
      "source_id" => Map.get(event, :source_id),
      "from_source_id" => Map.get(event, :from_source_id),
      "to_source_id" => Map.get(event, :to_source_id),
      "reason" => Map.get(event, :reason),
      "message" => Map.get(event, :message),
      "details_json" => Map.get(event, :details_json)
    }
  end

  defp normalize_ts(%DateTime{} = ts), do: DateTime.to_iso8601(ts)

  defp normalize_ts(%NaiveDateTime{} = ts),
    do: ts |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp normalize_ts(ts), do: ts
end

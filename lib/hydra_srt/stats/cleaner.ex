defmodule HydraSrt.Stats.Cleaner do
  @moduledoc false
  use GenServer
  require Logger

  alias HydraSrt.Stats.Duckdb

  @default_retention_hours 24
  @default_events_retention_hours 24 * 7
  @default_clean_interval_ms :timer.hours(1)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    retention_hours = Keyword.get(opts, :retention_hours, @default_retention_hours)

    events_retention_hours =
      Keyword.get(opts, :events_retention_hours, @default_events_retention_hours)

    clean_interval_ms = Keyword.get(opts, :clean_interval_ms, @default_clean_interval_ms)

    schedule_clean(clean_interval_ms)

    {:ok,
     %{
       retention_hours: retention_hours,
       events_retention_hours: events_retention_hours,
       clean_interval_ms: clean_interval_ms
     }}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_result = Duckdb.delete_older_than(state.retention_hours)
    events_cleanup_result = Duckdb.delete_events_older_than(state.events_retention_hours)
    log_cleanup_result(cleanup_result, state.retention_hours)
    log_events_cleanup_result(events_cleanup_result, state.events_retention_hours)
    schedule_clean(state.clean_interval_ms)
    {:noreply, state}
  end

  @spec schedule_clean(pos_integer()) :: reference()
  def schedule_clean(clean_interval_ms)
      when is_integer(clean_interval_ms) and clean_interval_ms > 0 do
    Process.send_after(self(), :cleanup, clean_interval_ms)
  end

  @spec log_cleanup_result(:ok | {:error, term()}, pos_integer()) :: :ok
  def log_cleanup_result(:ok, _retention_hours), do: :ok

  def log_cleanup_result({:error, reason}, retention_hours) do
    Logger.error(
      "Stats cleaner failed retention_hours=#{retention_hours} reason=#{inspect(reason)}"
    )

    :ok
  end

  @spec log_events_cleanup_result(:ok | {:error, term()}, pos_integer()) :: :ok
  def log_events_cleanup_result(:ok, _retention_hours), do: :ok

  def log_events_cleanup_result({:error, reason}, retention_hours) do
    Logger.error(
      "Stats cleaner failed for events retention_hours=#{retention_hours} reason=#{inspect(reason)}"
    )

    :ok
  end
end

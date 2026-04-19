defmodule HydraSrt.StatsRetention do
  @moduledoc false

  use GenServer

  require Logger

  @name __MODULE__
  @interval_ms 60 * 60 * 1000
  @retention_hours 24

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @impl true
  def init(_opts) do
    {:ok, %{}, {:continue, :prune_on_startup}}
  end

  @impl true
  def handle_continue(:prune_on_startup, state) do
    do_prune()
    schedule_prune()
    {:noreply, state}
  end

  @impl true
  def handle_info(:prune, state) do
    do_prune()
    schedule_prune()
    {:noreply, state}
  end

  def do_prune do
    deleted = HydraSrt.StatsHistory.prune_older_than_hours(@retention_hours)

    if deleted > 0 do
      Logger.info(
        "Stats retention: deleted #{deleted} snapshot(s) older than #{@retention_hours}h"
      )
    end

    :ok
  rescue
    error ->
      Logger.error("Stats retention prune failed: #{inspect(error)}")
      :ok
  end

  def schedule_prune do
    Process.send_after(self(), :prune, @interval_ms)
  end
end

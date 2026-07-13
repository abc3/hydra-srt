defmodule HydraSrt.Stats.Cleaner do
  @moduledoc false
  use GenServer
  require Logger

  @default_clean_interval_ms :timer.hours(1)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    clean_interval_ms = Keyword.get(opts, :clean_interval_ms, @default_clean_interval_ms)

    schedule_clean(clean_interval_ms)

    {:ok, %{clean_interval_ms: clean_interval_ms}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    Logger.debug("Stats cleaner skipped because VictoriaMetrics and VictoriaLogs own retention")
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

  @spec log_pipeline_logs_cleanup_result(:ok | {:error, term()}, pos_integer()) :: :ok
  def log_pipeline_logs_cleanup_result(:ok, _retention_hours), do: :ok

  def log_pipeline_logs_cleanup_result({:error, reason}, retention_hours) do
    Logger.error(
      "Stats cleaner failed for pipeline_logs retention_hours=#{retention_hours} reason=#{inspect(reason)}"
    )

    :ok
  end
end

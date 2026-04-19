defmodule HydraSrt.AuthCleanup do
  @moduledoc false
  use GenServer

  @default_interval :timer.hours(1)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    schedule_cleanup(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:cleanup, %{interval: interval} = state) do
    :ok = HydraSrt.Auth.delete_expired_sessions()
    schedule_cleanup(interval)
    {:noreply, state}
  end

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup, interval)
  end
end

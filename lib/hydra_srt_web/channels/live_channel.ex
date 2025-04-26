defmodule HydraSrtWeb.LiveChannel do
  use Phoenix.Channel
  require Logger

  @impl true
  def join("live:" <> route_id, _params, socket) do
    Phoenix.PubSub.subscribe(HydraSrt.PubSub, "stats:#{route_id}")
    {:ok, assign(socket, :route_id, route_id)}
  end

  @impl true
  def handle_info({:stats, stats}, socket) do
    push(socket, "stats", stats)
    {:noreply, socket}
  end
end

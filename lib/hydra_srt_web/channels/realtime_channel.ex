defmodule HydraSrtWeb.RealtimeChannel do
  use HydraSrtWeb, :channel

  @impl true
  def join("realtime", _payload, socket) do
    {:ok, assign(socket, :stats_subscribed, false)}
  end

  @impl true
  def handle_in("stats:subscribe", _payload, socket) do
    if socket.assigns[:stats_subscribed] do
      {:reply, :ok, socket}
    else
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "stats")
      {:reply, :ok, assign(socket, :stats_subscribed, true)}
    end
  end

  @impl true
  def handle_in("stats:unsubscribe", _payload, socket) do
    if socket.assigns[:stats_subscribed] do
      Phoenix.PubSub.unsubscribe(HydraSrt.PubSub, "stats")
      {:reply, :ok, assign(socket, :stats_subscribed, false)}
    else
      {:reply, :ok, socket}
    end
  end

  @impl true
  def handle_info({:stats, event}, socket) when is_map(event) do
    push(socket, "stats", event)
    {:noreply, socket}
  end
end

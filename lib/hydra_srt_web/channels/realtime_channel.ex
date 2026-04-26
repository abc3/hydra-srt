defmodule HydraSrtWeb.RealtimeChannel do
  use HydraSrtWeb, :channel

  @impl true
  def join("realtime", _payload, socket) do
    {:ok, assign(socket, :stats_subscribed, false) |> assign(:item_topics, MapSet.new())}
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
  def handle_in("item:subscribe", %{"item_id" => item_id}, socket) when is_binary(item_id) do
    topic = "item:" <> item_id
    item_topics = socket.assigns[:item_topics] || MapSet.new()

    if MapSet.member?(item_topics, topic) do
      {:reply, :ok, socket}
    else
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, topic)
      {:reply, :ok, assign(socket, :item_topics, MapSet.put(item_topics, topic))}
    end
  end

  def handle_in("item:subscribe", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_item_id"}}, socket}
  end

  @impl true
  def handle_in("item:unsubscribe", %{"item_id" => item_id}, socket) when is_binary(item_id) do
    topic = "item:" <> item_id
    item_topics = socket.assigns[:item_topics] || MapSet.new()

    if MapSet.member?(item_topics, topic) do
      Phoenix.PubSub.unsubscribe(HydraSrt.PubSub, topic)
      {:reply, :ok, assign(socket, :item_topics, MapSet.delete(item_topics, topic))}
    else
      {:reply, :ok, socket}
    end
  end

  def handle_in("item:unsubscribe", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_item_id"}}, socket}
  end

  @impl true
  def handle_info({:stats, event}, socket) when is_map(event) do
    push(socket, "stats", event)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:item_status, event}, socket) when is_map(event) do
    push(socket, "item_status", event)
    {:noreply, socket}
  end
end

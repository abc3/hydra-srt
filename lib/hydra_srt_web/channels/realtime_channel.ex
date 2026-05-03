defmodule HydraSrtWeb.RealtimeChannel do
  use HydraSrtWeb, :channel

  @system_pipelines_interval_ms 5_000

  @impl true
  def join("realtime", _payload, socket) do
    {:ok,
     socket
     |> assign(:stats_subscribed, false)
     |> assign(:system_pipelines_subscribed, false)
     |> assign(:item_topics, MapSet.new())
     |> assign(:event_topics, MapSet.new())}
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
  def handle_in("system_pipelines:subscribe", _payload, socket) do
    if socket.assigns[:system_pipelines_subscribed] do
      {:reply, :ok, socket}
    else
      push(socket, "system_pipelines", system_pipelines_snapshot())
      Process.send_after(self(), :push_system_pipelines, @system_pipelines_interval_ms)
      {:reply, :ok, assign(socket, :system_pipelines_subscribed, true)}
    end
  end

  @impl true
  def handle_in("system_pipelines:unsubscribe", _payload, socket) do
    if socket.assigns[:system_pipelines_subscribed] do
      {:reply, :ok, assign(socket, :system_pipelines_subscribed, false)}
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
  def handle_in("events:subscribe", %{"route_id" => route_id}, socket) when is_binary(route_id) do
    topic = "events:" <> route_id
    event_topics = socket.assigns[:event_topics] || MapSet.new()

    if MapSet.member?(event_topics, topic) do
      {:reply, :ok, socket}
    else
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, topic)
      {:reply, :ok, assign(socket, :event_topics, MapSet.put(event_topics, topic))}
    end
  end

  def handle_in("events:subscribe", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_route_id"}}, socket}
  end

  @impl true
  def handle_in("events:unsubscribe", %{"route_id" => route_id}, socket)
      when is_binary(route_id) do
    topic = "events:" <> route_id
    event_topics = socket.assigns[:event_topics] || MapSet.new()

    if MapSet.member?(event_topics, topic) do
      Phoenix.PubSub.unsubscribe(HydraSrt.PubSub, topic)
      {:reply, :ok, assign(socket, :event_topics, MapSet.delete(event_topics, topic))}
    else
      {:reply, :ok, socket}
    end
  end

  def handle_in("events:unsubscribe", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_route_id"}}, socket}
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

  @impl true
  def handle_info({:item_source, event}, socket) when is_map(event) do
    push(socket, "item_source", event)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:event, event}, socket) when is_map(event) do
    push(socket, "event", event)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:push_system_pipelines, socket) do
    if socket.assigns[:system_pipelines_subscribed] do
      push(socket, "system_pipelines", system_pipelines_snapshot())
      Process.send_after(self(), :push_system_pipelines, @system_pipelines_interval_ms)
    end

    {:noreply, socket}
  end

  defp system_pipelines_snapshot do
    %{
      pipelines: system_pipelines(),
      routes: routes()
    }
  end

  defp system_pipelines do
    case HydraSrt.ProcessMonitor.list_pipeline_processes() do
      pipelines when is_list(pipelines) -> pipelines
      {:error, _reason} -> []
    end
  end

  defp routes do
    case HydraSrt.Db.get_all_routes(false) do
      {:ok, routes} -> routes
    end
  end
end

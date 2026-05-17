defmodule HydraSrt.Notifications.Telegram do
  @moduledoc false
  use GenServer
  require Logger

  alias HydraSrt.Api.Notification
  alias HydraSrt.Db

  @events_topic "events:all"
  @default_min_interval_ms 5_000

  def start_link(opts \\ %{}) when is_map(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def reload_config do
    GenServer.call(__MODULE__, :reload_config)
  end

  def suspend_notifications do
    GenServer.call(__MODULE__, :suspend_notifications)
  end

  def resume_notifications do
    GenServer.call(__MODULE__, :resume_notifications)
  end

  @impl true
  def init(_opts) do
    min_interval_ms =
      Application.get_env(:hydra_srt, :telegram_min_interval_ms, @default_min_interval_ms)

    {:ok,
     load_state(%{
       subscribed: false,
       suppressed: false,
       last_sent_by_route: %{},
       min_interval_ms: min_interval_ms
     })}
  end

  @impl true
  def handle_call(:reload_config, _from, state) do
    {:reply, :ok, load_state(state)}
  end

  def handle_call(:suspend_notifications, _from, state) do
    {:reply, :ok, %{state | suppressed: true}}
  end

  def handle_call(:resume_notifications, _from, state) do
    {:reply, :ok, %{state | suppressed: false}}
  end

  @impl true
  def handle_info({:event, %{"event_type" => "route_status_change"} = event}, state) do
    if should_send_event?(state, event) do
      message = format_route_status_message(event)

      _ =
        Task.Supervisor.start_child(HydraSrt.TaskSupervisor, fn ->
          send_message(state.bot_token, state.chat_id, message)
        end)

      {:noreply, remember_last_sent(state, event)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:event, _event}, state) do
    {:noreply, state}
  end

  def load_state(%{subscribed: subscribed} = state) do
    if subscribed do
      Phoenix.PubSub.unsubscribe(HydraSrt.PubSub, @events_topic)
    end

    base_state = %{
      enabled: false,
      bot_token: "",
      chat_id: "",
      subscribed: false,
      suppressed: Map.get(state, :suppressed, false),
      last_sent_by_route: Map.get(state, :last_sent_by_route, %{}),
      min_interval_ms: Map.get(state, :min_interval_ms, @default_min_interval_ms)
    }

    case Db.get_notification_by_type(Notification.telegram_type()) do
      %Notification{enabled: true, config: config} when is_map(config) ->
        bot_token = config_value(config, "bot_token")
        chat_id = config_value(config, "chat_id")

        if bot_token != "" and chat_id != "" do
          :ok = Phoenix.PubSub.subscribe(HydraSrt.PubSub, @events_topic)

          %{base_state | enabled: true, bot_token: bot_token, chat_id: chat_id, subscribed: true}
        else
          base_state
        end

      _ ->
        base_state
    end
  end

  def should_send_event?(state, event) when is_map(state) and is_map(event) do
    not state.suppressed and
      state.enabled and
      state.bot_token != "" and
      state.chat_id != "" and
      not throttled?(state, event)
  end

  def throttled?(state, event) when is_map(state) and is_map(event) do
    route_id = Map.get(event, "route_id")

    if is_binary(route_id) and route_id != "" and is_integer(state.min_interval_ms) and
         state.min_interval_ms > 0 do
      now_ms = System.monotonic_time(:millisecond)
      last_sent_ms = Map.get(state.last_sent_by_route, route_id)
      is_integer(last_sent_ms) and now_ms - last_sent_ms < state.min_interval_ms
    else
      false
    end
  end

  def remember_last_sent(state, event) when is_map(state) and is_map(event) do
    route_id = Map.get(event, "route_id")

    if is_binary(route_id) and route_id != "" do
      now_ms = System.monotonic_time(:millisecond)
      last_sent_by_route = Map.put(state.last_sent_by_route || %{}, route_id, now_ms)
      %{state | last_sent_by_route: last_sent_by_route}
    else
      state
    end
  end

  def format_route_status_message(event) do
    route_id = Map.get(event, "route_id")
    {old_status, new_status} = status_transition_from_event(event)
    route_label = route_label(route_id)

    "Route \"#{route_label}\" (#{route_id}): #{old_status} → #{new_status}"
  end

  def status_transition_from_event(%{"details_json" => details_json})
      when is_binary(details_json) do
    case Jason.decode(details_json) do
      {:ok, %{"old_status" => old, "new_status" => new}} -> {old, new}
      _ -> {"unknown", "unknown"}
    end
  end

  def status_transition_from_event(_event), do: {"unknown", "unknown"}

  def route_label(route_id) when is_binary(route_id) do
    case Db.get_route(route_id, false) do
      {:ok, %{"name" => name}} when is_binary(name) and name != "" -> name
      {:ok, _} -> route_id
      {:error, _} -> route_id
    end
  end

  def route_label(_route_id), do: "unknown"

  def send_message(bot_token, chat_id, text) do
    case telegram_request(bot_token, "sendMessage", chat_id: chat_id, text: text) do
      {:ok, _response} ->
        :ok

      {:error, reason} ->
        Logger.error("Telegram notification failed reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  def telegram_request(token, method, opts) do
    request_fun = Application.get_env(:hydra_srt, :telegram_request, &Telegram.Api.request/3)
    request_fun.(token, method, opts)
  end

  def config_value(config, key) when is_map(config) do
    value = Map.get(config, key) || Map.get(config, String.to_atom(key))

    case value do
      nil -> ""
      value when is_binary(value) -> String.trim(value)
      value -> value |> to_string() |> String.trim()
    end
  end
end

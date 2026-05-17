defmodule HydraSrt.Notifications.TelegramTest do
  use HydraSrt.DataCase, async: false

  alias HydraSrt.Api.Notification
  alias HydraSrt.Db
  alias HydraSrt.Notifications.Telegram, as: TelegramNotifier
  alias HydraSrt.Repo

  setup do
    Repo.delete_all(Notification)
    Ecto.Adapters.SQL.Sandbox.allow(HydraSrt.Repo, self(), TelegramNotifier)
    TelegramNotifier.resume_notifications()
    :ok
  end

  test "format_route_status_message includes status transition" do
    event = %{
      "route_id" => "route-1",
      "details_json" => Jason.encode!(%{"old_status" => "stopped", "new_status" => "processing"})
    }

    message = TelegramNotifier.format_route_status_message(event)
    assert message =~ "stopped"
    assert message =~ "processing"
    assert message =~ "route-1"
  end

  test "send_message uses configured telegram request function" do
    test_pid = self()

    :ok =
      Application.put_env(:hydra_srt, :telegram_request, fn token, method, opts ->
        send(test_pid, {:telegram_request, token, method, opts})
        {:ok, %{}}
      end)

    on_exit(fn -> Application.delete_env(:hydra_srt, :telegram_request) end)

    assert :ok = TelegramNotifier.send_message("token", "123", "hello")

    assert_receive {:telegram_request, "token", "sendMessage", [chat_id: "123", text: "hello"]}
  end

  test "load_state subscribes when telegram notifications are enabled" do
    assert {:ok, _} =
             Db.upsert_telegram_notification(%{
               "enabled" => true,
               "bot_token" => "123:abc",
               "chat_id" => "42"
             })

    state = TelegramNotifier.load_state(%{subscribed: false})

    assert state.subscribed == true
    assert state.enabled == true
    assert state.bot_token == "123:abc"
    assert state.chat_id == "42"

    TelegramNotifier.load_state(%{subscribed: true})
  end

  test "load_state unsubscribes when notifications are disabled" do
    assert {:ok, _} =
             Db.upsert_telegram_notification(%{
               "enabled" => true,
               "bot_token" => "123:abc",
               "chat_id" => "42"
             })

    subscribed_state = TelegramNotifier.load_state(%{subscribed: false})
    assert subscribed_state.subscribed == true

    assert {:ok, _} =
             Db.upsert_telegram_notification(%{
               "enabled" => false,
               "chat_id" => "42"
             })

    disabled_state = TelegramNotifier.load_state(%{subscribed: true})
    assert disabled_state.subscribed == false
    assert disabled_state.enabled == false
  end

  test "forwards route_status_change pubsub events to telegram request" do
    test_pid = self()

    :ok =
      Application.put_env(:hydra_srt, :telegram_request, fn token, method, opts ->
        send(test_pid, {:telegram_request, token, method, opts})
        {:ok, %{}}
      end)

    on_exit(fn -> Application.delete_env(:hydra_srt, :telegram_request) end)

    assert {:ok, _} =
             Db.upsert_telegram_notification(%{
               "enabled" => true,
               "bot_token" => "123:abc",
               "chat_id" => "42"
             })

    TelegramNotifier.reload_config()

    :ok =
      Phoenix.PubSub.broadcast(HydraSrt.PubSub, "events:all", {
        :event,
        %{
          "event_type" => "route_status_change",
          "route_id" => "route-1",
          "details_json" =>
            Jason.encode!(%{"old_status" => "stopped", "new_status" => "processing"})
        }
      })

    assert_receive {:telegram_request, "123:abc", "sendMessage", opts}
    assert Keyword.get(opts, :chat_id) == "42"
    assert String.contains?(Keyword.get(opts, :text), "stopped")
    assert String.contains?(Keyword.get(opts, :text), "processing")
  end

  test "suspend_notifications blocks event delivery until resumed" do
    test_pid = self()

    :ok =
      Application.put_env(:hydra_srt, :telegram_request, fn _token, _method, _opts ->
        send(test_pid, :telegram_called)
        {:ok, %{}}
      end)

    on_exit(fn -> Application.delete_env(:hydra_srt, :telegram_request) end)

    assert {:ok, _} =
             Db.upsert_telegram_notification(%{
               "enabled" => true,
               "bot_token" => "123:abc",
               "chat_id" => "42"
             })

    TelegramNotifier.reload_config()
    TelegramNotifier.suspend_notifications()

    :ok =
      Phoenix.PubSub.broadcast(HydraSrt.PubSub, "events:all", {
        :event,
        %{
          "event_type" => "route_status_change",
          "route_id" => "route-2",
          "details_json" =>
            Jason.encode!(%{"old_status" => "stopped", "new_status" => "processing"})
        }
      })

    refute_receive :telegram_called, 200

    TelegramNotifier.resume_notifications()

    :ok =
      Phoenix.PubSub.broadcast(HydraSrt.PubSub, "events:all", {
        :event,
        %{
          "event_type" => "route_status_change",
          "route_id" => "route-2",
          "details_json" =>
            Jason.encode!(%{"old_status" => "processing", "new_status" => "failed"})
        }
      })

    assert_receive :telegram_called
  end

  test "throttles consecutive notifications for the same route" do
    test_pid = self()

    :ok =
      Application.put_env(:hydra_srt, :telegram_request, fn _token, _method, _opts ->
        send(test_pid, :telegram_called)
        {:ok, %{}}
      end)

    on_exit(fn -> Application.delete_env(:hydra_srt, :telegram_request) end)

    assert {:ok, _} =
             Db.upsert_telegram_notification(%{
               "enabled" => true,
               "bot_token" => "123:abc",
               "chat_id" => "42"
             })

    TelegramNotifier.reload_config()

    :ok =
      Phoenix.PubSub.broadcast(HydraSrt.PubSub, "events:all", {
        :event,
        %{
          "event_type" => "route_status_change",
          "route_id" => "route-3",
          "details_json" =>
            Jason.encode!(%{"old_status" => "stopped", "new_status" => "starting"})
        }
      })

    :ok =
      Phoenix.PubSub.broadcast(HydraSrt.PubSub, "events:all", {
        :event,
        %{
          "event_type" => "route_status_change",
          "route_id" => "route-3",
          "details_json" =>
            Jason.encode!(%{"old_status" => "starting", "new_status" => "processing"})
        }
      })

    assert_receive :telegram_called
    refute_receive :telegram_called, 200
  end
end

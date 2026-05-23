defmodule HydraSrtWeb.NotificationController do
  use HydraSrtWeb, :controller
  require Logger

  alias HydraSrt.Api.Notification
  alias HydraSrt.Db
  alias HydraSrt.Notifications.Telegram

  action_fallback HydraSrtWeb.FallbackController

  def show_telegram(conn, _params) do
    notification = Db.get_notification_by_type(Notification.telegram_type())
    data(conn, serialize_telegram(notification))
  end

  def update_telegram(conn, %{"notification" => notification_params}) do
    with {:ok, notification} <- Db.upsert_telegram_notification(notification_params) do
      :ok = Telegram.reload_config()
      data(conn, serialize_telegram(notification))
    end
  end

  def update_telegram(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "notification payload is required"})
  end

  def test_telegram(conn, params) do
    stored_notification = Db.get_notification_by_type(Notification.telegram_type())
    notification_params = Map.get(params, "notification", %{})

    case resolve_test_delivery(stored_notification, notification_params) do
      {:ok, %{bot_token: bot_token, chat_id: chat_id}} ->
        case Telegram.send_message(bot_token, chat_id, "HydraSRT test notification") do
          :ok ->
            data(conn, %{sent: true})

          {:error, reason} ->
            Logger.error("Telegram API error while sending test notification: #{inspect(reason)}")

            conn
            |> put_status(:bad_gateway)
            |> json(%{error: "Telegram API error while sending notification"})
        end

      {:error, :disabled} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Telegram notifications are disabled"})

      {:error, :missing_credentials} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Telegram bot token and chat ID are required"})
    end
  end

  def resolve_test_delivery(stored_notification, notification_params)
      when is_map(notification_params) do
    existing_enabled =
      case stored_notification do
        %Notification{enabled: enabled} -> enabled
        _ -> false
      end

    enabled =
      if has_notification_key?(notification_params, "enabled") do
        Db.notification_param(notification_params, "enabled", existing_enabled)
      else
        existing_enabled
      end

    existing_config =
      case stored_notification do
        %Notification{config: config} when is_map(config) -> config
        _ -> %{}
      end

    incoming_config = Db.notification_config_params(notification_params)
    merged_config = Db.merge_telegram_config(existing_config, incoming_config)
    bot_token = Telegram.config_value(merged_config, "bot_token")
    chat_id = Telegram.config_value(merged_config, "chat_id")

    cond do
      not enabled ->
        {:error, :disabled}

      bot_token == "" or chat_id == "" ->
        {:error, :missing_credentials}

      true ->
        {:ok, %{bot_token: bot_token, chat_id: chat_id}}
    end
  end

  def has_notification_key?(attrs, key) when is_map(attrs) and is_binary(key) do
    HydraSrt.Helpers.has_string_key?(attrs, key)
  end

  def serialize_telegram(nil) do
    %{
      "type" => Notification.telegram_type(),
      "enabled" => false,
      "bot_token" => nil,
      "chat_id" => nil,
      "bot_token_configured" => false,
      "token_suffix" => nil
    }
  end

  def serialize_telegram(%Notification{} = notification) do
    config = notification.config || %{}
    bot_token = Telegram.config_value(config, "bot_token")
    chat_id = Telegram.config_value(config, "chat_id")

    %{
      "id" => notification.id,
      "type" => notification.type,
      "enabled" => notification.enabled,
      "bot_token" => mask_bot_token(bot_token),
      "chat_id" => if(chat_id == "", do: nil, else: chat_id),
      "bot_token_configured" => bot_token != "",
      "token_suffix" => token_suffix(bot_token)
    }
  end

  def mask_bot_token(""), do: nil
  def mask_bot_token(_token), do: "***"

  def token_suffix(""), do: nil

  def token_suffix(token) when is_binary(token) do
    if String.length(token) >= 4 do
      String.slice(token, -4, 4)
    else
      nil
    end
  end

  def data(conn, payload), do: json(conn, %{data: payload})
end

defmodule HydraSrt.Api.NotificationTest do
  use HydraSrt.DataCase, async: true

  alias HydraSrt.Api.Notification

  test "changeset requires telegram config when enabled" do
    changeset =
      Notification.changeset(%Notification{}, %{
        type: Notification.telegram_type(),
        enabled: true,
        config: %{}
      })

    refute changeset.valid?
    assert "bot token is required when notifications are enabled" in errors_on(changeset).config
  end

  test "changeset accepts valid telegram config when enabled" do
    changeset =
      Notification.changeset(%Notification{}, %{
        type: Notification.telegram_type(),
        enabled: true,
        config: %{"bot_token" => "123:abc", "chat_id" => "999"}
      })

    assert changeset.valid?
  end
end

defmodule HydraSrt.DbNotificationsTest do
  use HydraSrt.DataCase, async: true

  alias HydraSrt.Api.Notification
  alias HydraSrt.Db
  alias HydraSrt.Repo

  setup do
    Repo.delete_all(Notification)
    :ok
  end

  test "upsert_telegram_notification creates and updates singleton row" do
    assert {:ok, first} =
             Db.upsert_telegram_notification(%{
               "enabled" => true,
               "bot_token" => "123:abc",
               "chat_id" => "1"
             })

    assert {:ok, second} =
             Db.upsert_telegram_notification(%{
               "enabled" => true,
               "chat_id" => "2"
             })

    assert first.id == second.id
    assert second.config["bot_token"] == "123:abc"
    assert second.config["chat_id"] == "2"
    assert Repo.aggregate(Notification, :count, :id) == 1
  end
end

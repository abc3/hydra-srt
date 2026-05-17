defmodule HydraSrtWeb.NotificationControllerTest do
  use HydraSrtWeb.ConnCase, async: false

  alias HydraSrt.Api.Notification
  alias HydraSrt.Repo

  setup %{conn: conn} do
    Repo.delete_all(Notification)
    Ecto.Adapters.SQL.Sandbox.allow(HydraSrt.Repo, self(), HydraSrt.Notifications.Telegram)

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> log_in_user()

    {:ok, conn: conn}
  end

  describe "GET /api/notifications/telegram" do
    test "returns default payload when not configured", %{conn: conn} do
      conn = get(conn, ~p"/api/notifications/telegram")

      assert %{
               "enabled" => false,
               "bot_token" => nil,
               "bot_token_configured" => false
             } = json_response(conn, 200)["data"]
    end

    test "masks stored bot token", %{conn: conn} do
      conn =
        put(conn, ~p"/api/notifications/telegram", %{
          notification: %{
            enabled: false,
            bot_token: "1234567890:ABCDEF",
            chat_id: "42"
          }
        })

      assert json_response(conn, 200)["data"]["bot_token_configured"] == true

      conn = get(conn, ~p"/api/notifications/telegram")

      assert %{
               "bot_token" => "***",
               "bot_token_configured" => true,
               "token_suffix" => "CDEF",
               "chat_id" => "42"
             } = json_response(conn, 200)["data"]
    end
  end

  describe "PUT /api/notifications/telegram" do
    test "creates telegram notification settings", %{conn: conn} do
      conn =
        put(conn, ~p"/api/notifications/telegram", %{
          notification: %{
            enabled: true,
            bot_token: "123:token",
            chat_id: "99"
          }
        })

      assert %{
               "enabled" => true,
               "bot_token" => "***",
               "chat_id" => "99",
               "bot_token_configured" => true
             } = json_response(conn, 200)["data"]
    end

    test "keeps existing bot token when omitted", %{conn: conn} do
      conn =
        put(conn, ~p"/api/notifications/telegram", %{
          notification: %{enabled: true, bot_token: "123:secret", chat_id: "1"}
        })

      assert json_response(conn, 200)

      conn =
        put(conn, ~p"/api/notifications/telegram", %{
          notification: %{enabled: true, chat_id: "2"}
        })

      assert json_response(conn, 200)["data"]["chat_id"] == "2"

      conn = get(conn, ~p"/api/notifications/telegram")
      assert json_response(conn, 200)["data"]["bot_token_configured"] == true
    end

    test "renders validation errors when enabled without config", %{conn: conn} do
      conn =
        put(conn, ~p"/api/notifications/telegram", %{
          notification: %{enabled: true}
        })

      assert json_response(conn, 422)["errors"] != %{}
    end

    test "returns validation error when payload wrapper is missing", %{conn: conn} do
      conn = put(conn, ~p"/api/notifications/telegram", %{})
      assert json_response(conn, 422)["error"] == "notification payload is required"
    end
  end

  describe "POST /api/notifications/telegram/test" do
    test "sends test message when configured", %{conn: conn} do
      :ok =
        Application.put_env(:hydra_srt, :telegram_request, fn _token, "sendMessage", _opts ->
          {:ok, %{}}
        end)

      on_exit(fn -> Application.delete_env(:hydra_srt, :telegram_request) end)

      conn =
        put(conn, ~p"/api/notifications/telegram", %{
          notification: %{
            enabled: true,
            bot_token: "123:token",
            chat_id: "42"
          }
        })

      assert json_response(conn, 200)

      conn = post(conn, ~p"/api/notifications/telegram/test")
      assert json_response(conn, 200)["data"]["sent"] == true
    end

    test "tests unsaved credentials from request payload", %{conn: conn} do
      test_pid = self()

      :ok =
        Application.put_env(:hydra_srt, :telegram_request, fn token, "sendMessage", opts ->
          send(test_pid, {:telegram_request, token, opts})
          {:ok, %{}}
        end)

      on_exit(fn -> Application.delete_env(:hydra_srt, :telegram_request) end)

      conn =
        put(conn, ~p"/api/notifications/telegram", %{
          notification: %{
            enabled: false,
            bot_token: "stored:token",
            chat_id: "100"
          }
        })

      assert json_response(conn, 200)

      conn =
        post(conn, ~p"/api/notifications/telegram/test", %{
          notification: %{
            enabled: true,
            bot_token: "unsaved:token",
            chat_id: "200"
          }
        })

      assert json_response(conn, 200)["data"]["sent"] == true
      assert_receive {:telegram_request, "unsaved:token", opts}
      assert Keyword.get(opts, :chat_id) == "200"
    end
  end
end

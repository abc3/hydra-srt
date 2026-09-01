defmodule HydraSrtWeb.AuthControllerTest do
  use HydraSrtWeb.ConnCase, async: false

  @invalid_credentials %{
    "error" => %{
      "code" => "INVALID_CREDENTIALS",
      "message" => "Invalid username or password"
    }
  }

  test "valid credentials return a session token", %{conn: conn} do
    response =
      conn
      |> post(~p"/api/login", login: %{"user" => "admin", "password" => "password123"})
      |> json_response(200)

    assert is_binary(response["token"])
    assert response["token"] != ""
    assert response["user"] == "admin"
    assert HydraSrt.Auth.valid_session?(response["token"])
  end

  test "wrong password returns structured unauthorized response", %{conn: conn} do
    response =
      conn
      |> post(~p"/api/login", login: %{"user" => "admin", "password" => "wrong"})
      |> json_response(401)

    assert response == @invalid_credentials
  end

  test "unknown username returns the same response as a wrong password", %{conn: conn} do
    wrong_password_response =
      conn
      |> post(~p"/api/login", login: %{"user" => "admin", "password" => "wrong"})
      |> json_response(401)

    unknown_username_response =
      build_conn()
      |> post(~p"/api/login", login: %{"user" => "unknown", "password" => "password123"})
      |> json_response(401)

    assert wrong_password_response == @invalid_credentials
    assert unknown_username_response == wrong_password_response
  end

  test "missing login payload returns invalid request response", %{conn: conn} do
    response =
      conn
      |> post(~p"/api/login", %{"user" => "admin", "password" => "password123"})
      |> json_response(400)

    assert response == %{
             "error" => %{
               "code" => "INVALID_REQUEST",
               "message" => "Invalid request format"
             }
           }
  end

  test "missing password configuration rejects an empty submitted password", %{conn: conn} do
    original_password = Application.get_env(:hydra_srt, :api_auth_password)
    Application.put_env(:hydra_srt, :api_auth_password, nil)

    on_exit(fn -> Application.put_env(:hydra_srt, :api_auth_password, original_password) end)

    response =
      conn
      |> post(~p"/api/login", login: %{"user" => "admin", "password" => ""})
      |> json_response(401)

    assert response == @invalid_credentials
    refute Map.has_key?(response, "token")
  end
end

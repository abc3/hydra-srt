defmodule HydraSrtWeb.TokenControllerTest do
  use HydraSrtWeb.ConnCase

  alias HydraSrt.Db

  @mcp_accept "application/json, text/event-stream"

  setup %{conn: conn} do
    {:ok, conn: log_in_user(conn)}
  end

  describe "tokens" do
    test "lists tokens", %{conn: conn} do
      {:ok, _token, _raw} = Db.create_token(%{"name" => "cursor"})

      conn = get(conn, ~p"/api/tokens")
      response = json_response(conn, 200)

      names =
        response
        |> Map.fetch!("data")
        |> Enum.map(&Map.fetch!(&1, "name"))

      assert names == ["cursor"]
      refute Enum.any?(response["data"], &Map.has_key?(&1, "token"))
    end

    test "creates token and returns raw token once", %{conn: conn} do
      conn = post(conn, ~p"/api/tokens", token: %{"name" => "cursor"})
      data = json_response(conn, 201)["data"]

      assert data["name"] == "cursor"
      assert is_binary(data["token"])
      assert Db.authenticate_mcp_token(data["token"])
    end

    test "rejects duplicate token name", %{conn: conn} do
      assert {:ok, _, _} = Db.create_token(%{"name" => "cursor"})

      conn = post(conn, ~p"/api/tokens", token: %{"name" => "cursor"})
      assert json_response(conn, 422)
    end

    test "rejects blank token name", %{conn: conn} do
      conn = post(conn, ~p"/api/tokens", token: %{"name" => "   "})
      assert json_response(conn, 422)
    end

    test "updates token name", %{conn: conn} do
      {:ok, token, _raw} = Db.create_token(%{"name" => "old name"})

      conn = put(conn, ~p"/api/tokens/#{token.id}", token: %{"name" => "new name"})
      assert json_response(conn, 200)["data"]["name"] == "new name"
    end

    test "returns not found when updating missing token", %{conn: conn} do
      conn =
        put(conn, ~p"/api/tokens/#{Ecto.UUID.generate()}", token: %{"name" => "missing"})

      assert json_response(conn, 404)
    end

    test "deletes token", %{conn: conn} do
      {:ok, token, _raw} = Db.create_token(%{"name" => "temporary"})

      conn = delete(conn, ~p"/api/tokens/#{token.id}")
      assert response(conn, 204)
      assert Db.list_tokens() == []
    end

    test "returns not found when deleting missing token", %{conn: conn} do
      conn = delete(conn, ~p"/api/tokens/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end

    test "requires auth", %{conn: _conn} do
      conn = get(build_conn(), ~p"/api/tokens")

      assert json_response(conn, 403)["error"] == "Authorization header missing"
    end
  end

  describe "mcp auth" do
    test "rejects requests without bearer token" do
      conn = build_conn() |> post(~p"/mcp")
      response = json_response(conn, 401)
      assert response["jsonrpc"] == "2.0"
      assert response["error"]["message"] == "Authorization header missing"
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end

    test "rejects requests with invalid bearer token" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer invalid-token")
        |> post(~p"/mcp")

      response = json_response(conn, 401)
      assert response["jsonrpc"] == "2.0"
      assert response["error"]["message"] == "Unauthorized"
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end

    test "rejects basic auth header" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
        |> post(~p"/mcp")

      response = json_response(conn, 401)
      assert response["jsonrpc"] == "2.0"
      assert response["error"]["message"] == "Authorization header missing"
    end

    test "rejects bearer header without token value" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer ")
        |> post(~p"/mcp")

      response = json_response(conn, 401)
      assert response["jsonrpc"] == "2.0"
      assert response["error"]["message"] == "Unauthorized"
    end

    test "rejects login session token on mcp endpoint" do
      session_token = "test_session_#{System.unique_integer()}"
      {:ok, _session} = HydraSrt.Auth.create_session(session_token, "user_session_data")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> session_token)
        |> post(~p"/mcp")

      response = json_response(conn, 401)
      assert response["jsonrpc"] == "2.0"
      assert response["error"]["message"] == "Unauthorized"
    end

    test "accepts requests with valid bearer token and reaches MCP transport" do
      {:ok, _token, raw_token} = Db.create_token(%{"name" => "mcp client"})

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> raw_token)
        |> put_req_header("accept", @mcp_accept)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/mcp", "{}")

      assert conn.status == 400
      assert conn.resp_body =~ "jsonrpc"
      refute conn.resp_body =~ "Authorization header missing"
    end
  end
end

defmodule HydraSrtWeb.DashboardControllerTest do
  use HydraSrtWeb.ConnCase

  setup %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> log_in_user()

    {:ok, conn: conn}
  end

  test "returns the dashboard snapshot", %{conn: conn} do
    conn = get(conn, ~p"/api/dashboard")
    payload = json_response(conn, 200)

    assert is_binary(payload["generated_at"])
    assert is_boolean(payload["analytics_available"])
    assert is_map(payload["system"])
    assert %{"total" => 0, "statuses" => %{}} = payload["routes"]
    assert is_map(payload["failover"])
    assert is_map(payload["logs"])
    assert is_list(payload["network_series"])
    assert is_list(payload["status_series"])
    assert payload["attention"] == []
  end

  test "requires authentication", %{conn: conn} do
    conn = conn |> delete_req_header("authorization") |> get(~p"/api/dashboard")

    assert json_response(conn, 403)["error"] in ["Unauthorized", "Authorization header missing"]
  end
end

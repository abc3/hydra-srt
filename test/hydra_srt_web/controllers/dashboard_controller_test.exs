defmodule HydraSrtWeb.DashboardControllerTest do
  use HydraSrtWeb.ConnCase

  import HydraSrt.ApiFixtures

  alias HydraSrt.StatsStore

  setup %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> log_in_user()

    :ok = StatsStore.ensure_table()

    try do
      :ets.delete_all_objects(:hydra_srt_latest_stats)
    rescue
      _ -> :ok
    end

    {:ok, conn: conn}
  end

  test "returns summary with routes + throughput and requires auth", %{conn: conn} do
    r1 = route_fixture(%{enabled: true, status: "started"})
    _r2 = route_fixture(%{enabled: true, status: "stopped"})
    _r3 = route_fixture(%{enabled: false, status: "stopped"})

    :ok =
      StatsStore.put(r1.id, %{
        "source" => %{"bytes_in_per_sec" => 100},
        "destinations" => [%{"id" => "d1", "schema" => "UDP", "bytes_out_per_sec" => 40}]
      })

    conn = get(conn, ~p"/api/dashboard/summary")
    resp = json_response(conn, 200)

    assert resp["routes"]["total"] == 3
    assert resp["routes"]["started"] == 1
    assert resp["routes"]["enabled"] == 2

    assert resp["throughput"]["in_bytes_per_sec"] == 100
    assert resp["throughput"]["out_bytes_per_sec"] == 40
    assert resp["throughput"]["routes_with_stats"] == 1

    assert is_map(resp["system"])
    assert is_map(resp["nodes"])
    assert is_map(resp["pipelines"])
  end

  test "rejects request without bearer token", %{conn: conn} do
    conn = delete_req_header(conn, "authorization")
    conn = get(conn, ~p"/api/dashboard/summary")
    assert json_response(conn, 403)["error"] in ["Unauthorized", "Authorization header missing"]
  end
end

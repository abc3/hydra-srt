defmodule HydraSrtWeb.SrtCallerControllerTest do
  use HydraSrtWeb.ConnCase, async: false

  import HydraSrt.ApiFixtures

  alias HydraSrt.Api
  alias HydraSrt.Db

  setup %{conn: conn} do
    {:ok, conn: conn |> put_req_header("accept", "application/json") |> log_in_user()}
  end

  test "GET callers returns an empty live snapshot without a handler", %{conn: conn} do
    route = route_fixture()
    conn = get(conn, ~p"/api/routes/#{route.id}/srt/callers")

    assert json_response(conn, 200) == %{
             "data" => [],
             "meta" => %{"connected_callers" => 0}
           }
  end

  test "ban rejects malformed IP addresses", %{conn: conn} do
    route = route_fixture()
    conn = post(conn, ~p"/api/routes/#{route.id}/srt/callers/ban", %{"ip" => "not-an-ip"})

    assert json_response(conn, 422)["error"] =~ "valid IPv4 or IPv6"
  end

  test "ban returns 404 when the active source is not an SRT listener", %{conn: conn} do
    route = route_fixture()
    conn = post(conn, ~p"/api/routes/#{route.id}/srt/callers/ban", %{"ip" => "203.0.113.5"})

    assert response(conn, 404)
  end

  test "ban persists a denied IP without restarting the route", %{conn: conn} do
    route = route_fixture()

    {:ok, source} =
      Api.create_source(route.id, %{
        position: 0,
        enabled: true,
        name: "listener",
        schema: "SRT",
        mode: "listener",
        localaddress: "127.0.0.1",
        localport: HydraSrt.TestSupport.E2EHelpers.tcp_free_port!()
      })

    assert {:ok, _route} = Db.set_route_active_source(route.id, source.id, "manual")

    conn = post(conn, ~p"/api/routes/#{route.id}/srt/callers/ban", %{"ip" => "203.0.113.5"})
    body = json_response(conn, 200)["data"]
    assert body["endpoint_id"] == source.id
    assert body["limit_access"] == true
    assert body["denied_list"] == ["203.0.113.5/32"]

    assert {:ok, saved} = Db.get_source(route.id, source.id)
    assert saved["limit_access"] == true
    assert saved["denied_list"] == ["203.0.113.5/32"]

    conn = post(conn, ~p"/api/routes/#{route.id}/srt/callers/ban", %{"ip" => "203.0.113.5"})
    assert json_response(conn, 200)["data"]["denied_list"] == ["203.0.113.5/32"]
  end
end

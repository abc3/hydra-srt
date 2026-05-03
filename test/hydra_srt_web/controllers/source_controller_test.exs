defmodule HydraSrtWeb.SourceControllerTest do
  use HydraSrtWeb.ConnCase

  import HydraSrt.ApiFixtures

  @create_attrs %{
    "position" => 0,
    "enabled" => true,
    "name" => "primary",
    "schema" => "UDP",
    "schema_options" => %{"host" => "127.0.0.1", "port" => 5000}
  }

  @update_attrs %{
    "enabled" => false,
    "name" => "backup-a",
    "schema_options" => %{"host" => "127.0.0.1", "port" => 5001}
  }

  @invalid_attrs %{
    "position" => -1,
    "schema" => nil
  }

  setup %{conn: conn} do
    route = route_fixture()

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> log_in_user()

    {:ok, conn: conn, route: route}
  end

  test "index lists all sources", %{conn: conn, route: %{id: route_id}} do
    conn = get(conn, ~p"/api/routes/#{route_id}/sources")
    assert json_response(conn, 200)["data"] == []
  end

  test "create/show/update/delete source", %{conn: conn, route: %{id: route_id}} do
    conn = post(conn, ~p"/api/routes/#{route_id}/sources", source: @create_attrs)
    assert %{"id" => source_id} = json_response(conn, 201)["data"]

    conn = get(conn, ~p"/api/routes/#{route_id}/sources/#{source_id}")
    assert %{"id" => ^source_id, "name" => "primary"} = json_response(conn, 200)["data"]

    conn = patch(conn, ~p"/api/routes/#{route_id}/sources/#{source_id}", source: @update_attrs)

    assert %{"id" => ^source_id, "name" => "backup-a", "enabled" => false} =
             json_response(conn, 200)["data"]

    conn = delete(conn, ~p"/api/routes/#{route_id}/sources/#{source_id}")
    assert response(conn, 204)
  end

  test "create source invalid data returns 422", %{conn: conn, route: %{id: route_id}} do
    conn = post(conn, ~p"/api/routes/#{route_id}/sources", source: @invalid_attrs)
    assert json_response(conn, 422)["errors"] != %{}
  end

  test "reorder sources", %{conn: conn, route: route} do
    s1 = source_fixture(route, %{position: 0, name: "p"})
    s2 = source_fixture(route, %{position: 1, name: "b1"})

    conn = post(conn, ~p"/api/routes/#{route.id}/sources/reorder", source_ids: [s2.id, s1.id])
    sources = json_response(conn, 200)["data"]

    assert Enum.at(sources, 0)["id"] == s2.id
    assert Enum.at(sources, 0)["position"] == 0
    assert Enum.at(sources, 1)["id"] == s1.id
    assert Enum.at(sources, 1)["position"] == 1
  end
end

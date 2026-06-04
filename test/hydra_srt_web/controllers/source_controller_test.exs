defmodule HydraSrtWeb.SourceControllerTest do
  use HydraSrtWeb.ConnCase

  import HydraSrt.ApiFixtures

  @create_attrs %{
    "position" => 0,
    "enabled" => true,
    "name" => "primary",
    "schema" => "UDP",
    "host" => "127.0.0.1",
    "port" => 5000,
    "thumbnail_enabled" => true,
    "thumbnail_interval_ms" => 2000,
    "thumbnail_capture_policy" => "always"
  }

  @update_attrs %{
    "enabled" => false,
    "name" => "backup-a",
    "host" => "127.0.0.1",
    "port" => 5001
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

    assert %{
             "id" => ^source_id,
             "name" => "primary",
             "thumbnail_enabled" => true,
             "thumbnail_interval_ms" => 2000,
             "thumbnail_capture_policy" => "always"
           } = json_response(conn, 200)["data"]

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

  test "thumbnail endpoint returns cached JPEG", %{conn: conn, route: route} do
    source = source_fixture(route, %{position: 0, name: "p"})

    conn = get(conn, ~p"/api/routes/#{route.id}/sources/#{source.id}/thumbnail")
    assert json_response(conn, 404)["errors"] != %{}

    assert {:ok, _metadata} =
             HydraSrt.Thumbnails.put(route.id, source.id, <<0xFF, 0xD8, 0xFF, 0xD9>>,
               content_type: "image/jpeg"
             )

    conn = get(conn, ~p"/api/routes/#{route.id}/sources/#{source.id}/thumbnail")
    assert response(conn, 200) == <<0xFF, 0xD8, 0xFF, 0xD9>>
    assert get_resp_header(conn, "content-type") == ["image/jpeg; charset=utf-8"]
  end
end

defmodule HydraSrtWeb.RouteControllerTest do
  use HydraSrtWeb.ConnCase

  import HydraSrt.ApiFixtures

  @create_attrs %{
    "alias" => "some alias",
    "enabled" => true,
    "name" => "some name",
    "schema_status" => "processing",
    "status" => "some status",
    "started_at" => ~U[2025-02-18 14:51:00Z],
    "source" => %{},
    "stopped_at" => ~U[2025-02-18 14:51:00Z]
  }
  @update_attrs %{
    "alias" => "some updated alias",
    "enabled" => false,
    "name" => "some updated name",
    "schema_status" => "failed",
    "status" => "some updated status",
    "started_at" => ~U[2025-02-19 14:51:00Z],
    "source" => %{},
    "stopped_at" => ~U[2025-02-19 14:51:00Z]
  }
  @invalid_attrs %{
    "alias" => nil,
    "enabled" => nil,
    "name" => nil,
    "schema_status" => nil,
    "status" => nil,
    "started_at" => nil,
    "source" => nil,
    "stopped_at" => nil
  }

  setup %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> log_in_user()

    {:ok, conn: conn}
  end

  describe "index" do
    test "lists all routes", %{conn: conn} do
      conn = get(conn, ~p"/api/routes")
      assert json_response(conn, 200)["data"] == []
    end

    test "rejects request without bearer token", %{conn: conn} do
      conn = delete_req_header(conn, "authorization")
      conn = get(conn, ~p"/api/routes")
      assert json_response(conn, 403)["error"] in ["Unauthorized", "Authorization header missing"]
    end
  end

  describe "create route" do
    test "renders route when data is valid", %{conn: conn} do
      conn = post(conn, ~p"/api/routes", route: @create_attrs)
      assert %{"id" => id} = json_response(conn, 201)["data"]

      conn = get(conn, ~p"/api/routes/#{id}")

      assert %{
               "id" => ^id,
               "alias" => "some alias",
               "destinations" => [],
               "enabled" => true,
               "name" => "some name",
               "schema_status" => "processing",
               "source" => %{},
               "started_at" => "2025-02-18T14:51:00Z",
               "status" => "some status",
               "stopped_at" => "2025-02-18T14:51:00Z"
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = post(conn, ~p"/api/routes", route: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "update route" do
    setup [:create_route]

    test "renders route when data is valid", %{conn: conn, route: %{id: id}} do
      conn = put(conn, ~p"/api/routes/#{id}", route: @update_attrs)
      assert %{"id" => ^id} = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/api/routes/#{id}")

      assert %{
               "id" => ^id,
               "alias" => "some updated alias",
               "destinations" => [],
               "enabled" => false,
               "name" => "some updated name",
               "schema_status" => "failed",
               "source" => %{},
               "started_at" => "2025-02-19T14:51:00Z",
               "status" => "some updated status",
               "stopped_at" => "2025-02-19T14:51:00Z"
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn, route: %{id: id}} do
      conn = put(conn, ~p"/api/routes/#{id}", route: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "delete route" do
    setup [:create_route]

    test "deletes chosen route", %{conn: conn, route: %{id: id}} do
      conn = delete(conn, ~p"/api/routes/#{id}")
      assert response(conn, 204)

      conn = get(conn, ~p"/api/routes/#{id}")
      assert json_response(conn, 404)
    end
  end

  describe "test source" do
    test "returns probe validation error for invalid udp source", %{conn: conn} do
      conn =
        post(conn, ~p"/api/routes/test-source",
          route: %{
            "schema" => "UDP",
            "schema_options" => %{}
          }
        )

      assert json_response(conn, 422)["error"] == "UDP source is missing a valid port"
    end

    test "returns probe validation error for invalid srt source", %{conn: conn} do
      conn =
        post(conn, ~p"/api/routes/test-source",
          route: %{
            "schema" => "SRT",
            "schema_options" => %{
              "localaddress" => "127.0.0.1",
              "mode" => "listener"
            }
          }
        )

      assert json_response(conn, 422)["error"] == "SRT source is missing a valid port"
    end

    test "returns bad request when route parameter is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/routes/test-source", %{})

      assert json_response(conn, 400)["error"] == "Missing required 'route' parameter"
    end
  end

  describe "analytics" do
    setup [:create_route]

    test "returns route analytics from analytics database", %{conn: conn, route: %{id: id}} do
      conn = get(conn, "/api/routes/#{id}/analytics?window=last_hour")
      response = json_response(conn, 200)

      assert %{"data" => %{"meta" => meta, "points" => points}} = response
      assert meta["window"] == "last_hour"
      assert is_integer(meta["bucket_ms"])
      assert is_list(points)

      assert Enum.all?(points, fn point ->
               is_binary(point["timestamp"]) and is_map(point["destinations"])
             end)
    end
  end

  def create_route(_) do
    route = route_fixture()
    %{route: route}
  end
end

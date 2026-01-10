defmodule HydraSrtWeb.RouteControllerTest do
  use HydraSrtWeb.ConnCase

  import HydraSrt.DbFixtures

  @create_attrs %{
    "alias" => "some alias",
    "enabled" => true,
    "name" => "some name",
    "status" => "some status",
    "started_at" => ~U[2025-02-18 14:51:00Z],
    "source" => %{},
    "stopped_at" => ~U[2025-02-18 14:51:00Z]
  }
  @update_attrs %{
    "alias" => "some updated alias",
    "enabled" => false,
    "name" => "some updated name",
    "status" => "some updated status",
    "started_at" => ~U[2025-02-19 14:51:00Z],
    "source" => %{},
    "stopped_at" => ~U[2025-02-19 14:51:00Z]
  }
  @invalid_attrs %{
    "alias" => nil,
    "enabled" => nil,
    "name" => nil,
    "status" => nil,
    "started_at" => nil,
    "source" => nil,
    "stopped_at" => nil
  }

  setup %{conn: conn} do
    # Ensure clean slate for sequential tests if global cleanup fails
    :khepri.delete_many("**")

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

    test "renders route when data is valid", %{conn: conn, route: %{"id" => id}} do
      conn = put(conn, ~p"/api/routes/#{id}", route: @update_attrs)
      assert %{"id" => ^id} = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/api/routes/#{id}")

      assert %{
               "id" => ^id,
               "alias" => "some updated alias",
               "destinations" => [],
               "enabled" => false,
               "name" => "some updated name",
               "source" => %{},
               "started_at" => "2025-02-19T14:51:00Z",
               "status" => "some updated status",
               "stopped_at" => "2025-02-19T14:51:00Z"
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn, route: %{"id" => id}} do
      conn = put(conn, ~p"/api/routes/#{id}", route: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "delete route" do
    setup [:create_route]

    test "deletes chosen route", %{conn: conn, route: %{"id" => id}} do
      conn = delete(conn, ~p"/api/routes/#{id}")
      assert response(conn, 204)

      conn = get(conn, ~p"/api/routes/#{id}")
      assert json_response(conn, 404)
    end
  end

  defp create_route(_) do
    route = route_fixture()
    %{route: route}
  end
end

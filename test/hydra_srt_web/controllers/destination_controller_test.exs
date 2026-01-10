defmodule HydraSrtWeb.DestinationControllerTest do
  use HydraSrtWeb.ConnCase

  import HydraSrt.DbFixtures

  @create_attrs %{
    "alias" => "some alias",
    "enabled" => true,
    "name" => "some name",
    "status" => "some status",
    "started_at" => ~U[2025-02-19 16:24:00Z],
    "stopped_at" => ~U[2025-02-19 16:24:00Z]
  }
  @update_attrs %{
    "alias" => "some updated alias",
    "enabled" => false,
    "name" => "some updated name",
    "status" => "some updated status",
    "started_at" => ~U[2025-02-20 16:24:00Z],
    "stopped_at" => ~U[2025-02-20 16:24:00Z]
  }
  @invalid_attrs %{
    "alias" => nil,
    "enabled" => nil,
    "name" => nil,
    "status" => nil,
    "started_at" => nil,
    "stopped_at" => nil
  }

  setup %{conn: conn} do
    route = route_fixture()

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> log_in_user()

    {:ok, conn: conn, route: route}
  end

  describe "index" do
    test "lists all destinations", %{conn: conn, route: %{"id" => route_id}} do
      conn = get(conn, ~p"/api/routes/#{route_id}/destinations")
      assert json_response(conn, 200)["data"] == []
    end
  end

  describe "create destination" do
    test "renders destination when data is valid", %{conn: conn, route: %{"id" => route_id}} do
      conn = post(conn, ~p"/api/routes/#{route_id}/destinations", destination: @create_attrs)
      assert %{"id" => id} = json_response(conn, 201)["data"]

      conn = get(conn, ~p"/api/routes/#{route_id}/destinations/#{id}")

      assert %{
               "id" => ^id,
               "alias" => "some alias",
               "enabled" => true,
               "name" => "some name",
               "started_at" => "2025-02-19T16:24:00Z",
               "status" => "some status",
               "stopped_at" => "2025-02-19T16:24:00Z"
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn, route: %{"id" => route_id}} do
      conn = post(conn, ~p"/api/routes/#{route_id}/destinations", destination: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "update destination" do
    setup [:create_destination]

    test "renders destination when data is valid", %{
      conn: conn,
      route: %{"id" => route_id},
      destination: %{"id" => dest_id}
    } do
      conn =
        put(conn, ~p"/api/routes/#{route_id}/destinations/#{dest_id}", destination: @update_attrs)

      assert %{"id" => ^dest_id} = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/api/routes/#{route_id}/destinations/#{dest_id}")

      assert %{
               "id" => ^dest_id,
               "alias" => "some updated alias",
               "enabled" => false,
               "name" => "some updated name",
               "started_at" => "2025-02-20T16:24:00Z",
               "status" => "some updated status",
               "stopped_at" => "2025-02-20T16:24:00Z"
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{
      conn: conn,
      route: %{"id" => route_id},
      destination: %{"id" => dest_id}
    } do
      conn =
        put(conn, ~p"/api/routes/#{route_id}/destinations/#{dest_id}",
          destination: @invalid_attrs
        )

      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "delete destination" do
    setup [:create_destination]

    test "deletes chosen destination", %{
      conn: conn,
      route: %{"id" => route_id},
      destination: %{"id" => dest_id}
    } do
      conn = delete(conn, ~p"/api/routes/#{route_id}/destinations/#{dest_id}")
      assert response(conn, 204)

      conn = get(conn, ~p"/api/routes/#{route_id}/destinations/#{dest_id}")
      assert json_response(conn, 404)
    end
  end

  defp create_destination(%{route: route}) do
    destination = destination_fixture(route)
    %{destination: destination}
  end
end

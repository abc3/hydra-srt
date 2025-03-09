defmodule HydraSrtWeb.DestinationControllerTest do
  use HydraSrtWeb.ConnCase

  import HydraSrt.ApiFixtures

  alias HydraSrt.Api.Destination

  @create_attrs %{
    alias: "some alias",
    enabled: true,
    name: "some name",
    status: "some status",
    started_at: ~U[2025-02-19 16:24:00Z],
    stopped_at: ~U[2025-02-19 16:24:00Z]
  }
  @update_attrs %{
    alias: "some updated alias",
    enabled: false,
    name: "some updated name",
    status: "some updated status",
    started_at: ~U[2025-02-20 16:24:00Z],
    stopped_at: ~U[2025-02-20 16:24:00Z]
  }
  @invalid_attrs %{alias: nil, enabled: nil, name: nil, status: nil, started_at: nil, stopped_at: nil}

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "index" do
    test "lists all destinations", %{conn: conn} do
      conn = get(conn, ~p"/api/destinations")
      assert json_response(conn, 200)["data"] == []
    end
  end

  describe "create destination" do
    test "renders destination when data is valid", %{conn: conn} do
      conn = post(conn, ~p"/api/destinations", destination: @create_attrs)
      assert %{"id" => id} = json_response(conn, 201)["data"]

      conn = get(conn, ~p"/api/destinations/#{id}")

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

    test "renders errors when data is invalid", %{conn: conn} do
      conn = post(conn, ~p"/api/destinations", destination: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "update destination" do
    setup [:create_destination]

    test "renders destination when data is valid", %{conn: conn, destination: %Destination{id: id} = destination} do
      conn = put(conn, ~p"/api/destinations/#{destination}", destination: @update_attrs)
      assert %{"id" => ^id} = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/api/destinations/#{id}")

      assert %{
               "id" => ^id,
               "alias" => "some updated alias",
               "enabled" => false,
               "name" => "some updated name",
               "started_at" => "2025-02-20T16:24:00Z",
               "status" => "some updated status",
               "stopped_at" => "2025-02-20T16:24:00Z"
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn, destination: destination} do
      conn = put(conn, ~p"/api/destinations/#{destination}", destination: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "delete destination" do
    setup [:create_destination]

    test "deletes chosen destination", %{conn: conn, destination: destination} do
      conn = delete(conn, ~p"/api/destinations/#{destination}")
      assert response(conn, 204)

      assert_error_sent 404, fn ->
        get(conn, ~p"/api/destinations/#{destination}")
      end
    end
  end

  defp create_destination(_) do
    destination = destination_fixture()
    %{destination: destination}
  end
end

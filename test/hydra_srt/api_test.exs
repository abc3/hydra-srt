defmodule HydraSrt.ApiTest do
  use HydraSrt.DataCase

  alias HydraSrt.Api

  describe "routes" do
    alias HydraSrt.Api.Route

    import HydraSrt.ApiFixtures

    @invalid_attrs %{
      alias: nil,
      enabled: nil,
      name: nil,
      status: nil,
      started_at: nil,
      source: nil,
      destinations: nil,
      stopped_at: nil
    }

    test "list_routes/0 returns all routes" do
      route = route_fixture()
      assert Api.list_routes() == [route]
    end

    test "get_route!/1 returns the route with given id" do
      route = route_fixture()
      assert Api.get_route!(route.id) == route
    end

    test "create_route/1 with valid data creates a route" do
      valid_attrs = %{
        alias: "some alias",
        enabled: true,
        name: "some name",
        status: "some status",
        started_at: ~U[2025-02-18 14:51:00Z],
        source: %{},
        destinations: %{},
        stopped_at: ~U[2025-02-18 14:51:00Z]
      }

      assert {:ok, %Route{} = route} = Api.create_route(valid_attrs)
      assert route.alias == "some alias"
      assert route.enabled == true
      assert route.name == "some name"
      assert route.status == "some status"
      assert route.started_at == ~U[2025-02-18 14:51:00Z]
      assert route.source == %{}
      assert route.destinations == %{}
      assert route.stopped_at == ~U[2025-02-18 14:51:00Z]
    end

    test "create_route/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Api.create_route(@invalid_attrs)
    end

    test "update_route/2 with valid data updates the route" do
      route = route_fixture()

      update_attrs = %{
        alias: "some updated alias",
        enabled: false,
        name: "some updated name",
        status: "some updated status",
        started_at: ~U[2025-02-19 14:51:00Z],
        source: %{},
        destinations: %{},
        stopped_at: ~U[2025-02-19 14:51:00Z]
      }

      assert {:ok, %Route{} = route} = Api.update_route(route, update_attrs)
      assert route.alias == "some updated alias"
      assert route.enabled == false
      assert route.name == "some updated name"
      assert route.status == "some updated status"
      assert route.started_at == ~U[2025-02-19 14:51:00Z]
      assert route.source == %{}
      assert route.destinations == %{}
      assert route.stopped_at == ~U[2025-02-19 14:51:00Z]
    end

    test "update_route/2 with invalid data returns error changeset" do
      route = route_fixture()
      assert {:error, %Ecto.Changeset{}} = Api.update_route(route, @invalid_attrs)
      assert route == Api.get_route!(route.id)
    end

    test "delete_route/1 deletes the route" do
      route = route_fixture()
      assert {:ok, %Route{}} = Api.delete_route(route)
      assert_raise Ecto.NoResultsError, fn -> Api.get_route!(route.id) end
    end

    test "change_route/1 returns a route changeset" do
      route = route_fixture()
      assert %Ecto.Changeset{} = Api.change_route(route)
    end
  end

  describe "destinations" do
    alias HydraSrt.Api.Destination

    import HydraSrt.ApiFixtures

    @invalid_attrs %{
      alias: nil,
      enabled: nil,
      name: nil,
      status: nil,
      started_at: nil,
      stopped_at: nil
    }

    test "list_destinations/0 returns all destinations" do
      destination = destination_fixture()
      assert Api.list_destinations() == [destination]
    end

    test "get_destination!/1 returns the destination with given id" do
      destination = destination_fixture()
      assert Api.get_destination!(destination.id) == destination
    end

    test "create_destination/1 with valid data creates a destination" do
      valid_attrs = %{
        alias: "some alias",
        enabled: true,
        name: "some name",
        status: "some status",
        started_at: ~U[2025-02-19 16:24:00Z],
        stopped_at: ~U[2025-02-19 16:24:00Z]
      }

      assert {:ok, %Destination{} = destination} = Api.create_destination(valid_attrs)
      assert destination.alias == "some alias"
      assert destination.enabled == true
      assert destination.name == "some name"
      assert destination.status == "some status"
      assert destination.started_at == ~U[2025-02-19 16:24:00Z]
      assert destination.stopped_at == ~U[2025-02-19 16:24:00Z]
    end

    test "create_destination/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Api.create_destination(@invalid_attrs)
    end

    test "update_destination/2 with valid data updates the destination" do
      destination = destination_fixture()

      update_attrs = %{
        alias: "some updated alias",
        enabled: false,
        name: "some updated name",
        status: "some updated status",
        started_at: ~U[2025-02-20 16:24:00Z],
        stopped_at: ~U[2025-02-20 16:24:00Z]
      }

      assert {:ok, %Destination{} = destination} =
               Api.update_destination(destination, update_attrs)

      assert destination.alias == "some updated alias"
      assert destination.enabled == false
      assert destination.name == "some updated name"
      assert destination.status == "some updated status"
      assert destination.started_at == ~U[2025-02-20 16:24:00Z]
      assert destination.stopped_at == ~U[2025-02-20 16:24:00Z]
    end

    test "update_destination/2 with invalid data returns error changeset" do
      destination = destination_fixture()
      assert {:error, %Ecto.Changeset{}} = Api.update_destination(destination, @invalid_attrs)
      assert destination == Api.get_destination!(destination.id)
    end

    test "delete_destination/1 deletes the destination" do
      destination = destination_fixture()
      assert {:ok, %Destination{}} = Api.delete_destination(destination)
      assert_raise Ecto.NoResultsError, fn -> Api.get_destination!(destination.id) end
    end

    test "change_destination/1 returns a destination changeset" do
      destination = destination_fixture()
      assert %Ecto.Changeset{} = Api.change_destination(destination)
    end
  end
end

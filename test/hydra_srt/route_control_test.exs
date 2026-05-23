defmodule HydraSrt.RouteControlTest do
  use HydraSrt.DataCase, async: true

  alias HydraSrt.DbFixtures
  alias HydraSrt.RouteControl

  describe "drop_runtime_status_fields/1" do
    test "removes runtime status keys" do
      params = %{
        "name" => "route-a",
        "status" => "processing",
        "schema_status" => "processing"
      }

      assert RouteControl.drop_runtime_status_fields(params) == %{"name" => "route-a"}
    end
  end

  describe "route_stopped?/1" do
    test "returns true for stopped and failed routes" do
      assert RouteControl.route_stopped?(%{"status" => "stopped"})
      assert RouteControl.route_stopped?(%{"status" => "failed"})
      assert RouteControl.route_stopped?(%{"status" => nil})
    end

    test "returns false for running routes" do
      refute RouteControl.route_stopped?(%{"status" => "processing"})
    end
  end

  describe "switch_route_source/2" do
    test "returns error when source is disabled" do
      route = DbFixtures.route_fixture()
      source = DbFixtures.source_fixture(route, %{"enabled" => false})

      assert {:error, :source_disabled} =
               RouteControl.switch_route_source(route["id"], source["id"])
    end

    test "switches source when route is stopped" do
      route = DbFixtures.route_fixture(%{"status" => "stopped", "schema_status" => "stopped"})
      source = DbFixtures.source_fixture(route, %{"enabled" => true, "position" => 0})

      _other =
        DbFixtures.source_fixture(route, %{"enabled" => true, "position" => 1, "name" => "backup"})

      assert {:ok, updated} = RouteControl.switch_route_source(route["id"], source["id"])
      assert updated["active_source_id"] == source["id"]
    end
  end
end

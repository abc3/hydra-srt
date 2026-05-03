defmodule HydraSrt.DbSourcesTest do
  use HydraSrt.DataCase

  alias HydraSrt.Db

  import HydraSrt.DbFixtures

  test "create/list/get/update/delete source" do
    route = route_fixture()

    assert {:ok, created} =
             Db.create_source(route["id"], %{
               "position" => 0,
               "enabled" => true,
               "name" => "primary",
               "schema" => "UDP",
               "schema_options" => %{"host" => "127.0.0.1", "port" => 5000}
             })

    assert {:ok, listed} = Db.get_all_sources(route["id"])
    assert length(listed) == 1
    assert hd(listed)["id"] == created["id"]

    assert {:ok, fetched} = Db.get_source(route["id"], created["id"])
    assert fetched["name"] == "primary"

    assert {:ok, updated} = Db.update_source(route["id"], created["id"], %{"name" => "backup-0"})
    assert updated["name"] == "backup-0"

    assert :ok = Db.del_source(route["id"], created["id"])
    assert {:ok, []} = Db.get_all_sources(route["id"])
  end

  test "route_to_map includes sources and backup fields" do
    route = route_fixture(%{"backup_config" => %{"mode" => "passive"}})
    source = source_fixture(route, %{"position" => 0, "name" => "primary"})

    assert {:ok, updated_route} = Db.set_route_active_source(route["id"], source["id"], "manual")
    assert updated_route["active_source_id"] == source["id"]
    assert updated_route["last_switch_reason"] == "manual"
    assert is_list(updated_route["sources"])
    assert length(updated_route["sources"]) == 1
  end

  test "set_route_active_source broadcasts item_source event" do
    route = route_fixture()
    source = source_fixture(route, %{"position" => 0})
    Phoenix.PubSub.subscribe(HydraSrt.PubSub, "item:#{route["id"]}")

    assert {:ok, _route} = Db.set_route_active_source(route["id"], source["id"], "manual")

    assert_receive {:item_source, payload}
    assert payload.item_id == route["id"]
    assert payload.active_source_id == source["id"]
    assert payload.last_switch_reason == "manual"
  end
end

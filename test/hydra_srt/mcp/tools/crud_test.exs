defmodule HydraSrt.Mcp.Tools.CrudTest do
  use HydraSrt.DataCase, async: false

  import HydraSrt.DbFixtures

  alias HydraSrt.Db
  alias HydraSrt.Mcp.ToolRegistry

  test "list_routes returns JSON-safe data with timestamps" do
    route = route_fixture(%{"name" => "mcp-list-routes"})

    assert {:ok, response} = ToolRegistry.dispatch("list_routes", %{})
    assert response.isError == false

    data = response.structured_content["data"]
    assert is_list(data)
    assert Enum.any?(data, &(&1["id"] == route["id"]))
    assert Jason.encode!(response.structured_content)
  end

  test "create_route returns JSON-safe route payload" do
    assert {:ok, response} =
             ToolRegistry.dispatch("create_route", %{
               "route" => %{
                 "name" => "mcp-create-route",
                 "alias" => "mcp alias",
                 "enabled" => true
               }
             })

    assert response.isError == false
    assert response.structured_content["data"]["name"] == "mcp-create-route"
    assert is_binary(response.structured_content["data"]["created_at"])
    assert Jason.encode!(response.structured_content)
  end

  test "list_sources returns JSON-safe source list" do
    route = route_fixture()
    source = source_fixture(route, %{"name" => "mcp-source"})

    assert {:ok, response} =
             ToolRegistry.dispatch("list_sources", %{"route_id" => route["id"]})

    assert response.isError == false
    assert Enum.any?(response.structured_content["data"], &(&1["id"] == source["id"]))
    assert Jason.encode!(response.structured_content)
  end

  test "list_destinations returns JSON-safe destination list" do
    route = route_fixture()
    destination = destination_fixture(route, %{"name" => "mcp-destination"})

    assert {:ok, response} =
             ToolRegistry.dispatch("list_destinations", %{"route_id" => route["id"]})

    assert response.isError == false
    assert Enum.any?(response.structured_content["data"], &(&1["id"] == destination["id"]))
    assert Jason.encode!(response.structured_content)
  end

  test "list_tags returns JSON-safe tag timestamps" do
    {:ok, tag} = Db.create_tag(%{"name" => "mcp-tag"})

    assert {:ok, response} = ToolRegistry.dispatch("list_tags", %{})
    assert response.isError == false

    listed = Enum.find(response.structured_content["data"], &(&1["id"] == tag.id))
    assert listed["name"] == "mcp-tag"
    assert is_binary(listed["inserted_at"])
    assert is_binary(listed["updated_at"])
    assert Jason.encode!(response.structured_content)
  end

  test "get_route_analytics returns missing route_id error" do
    assert {:ok, response} = ToolRegistry.dispatch("get_route_analytics", %{})
    assert response.isError == true
    assert response.structured_content["error"] =~ "route_id"
  end

  test "delete_route removes route and returns deleted envelope" do
    route = route_fixture(%{"name" => "mcp-delete-route"})

    assert {:ok, response} =
             ToolRegistry.dispatch("delete_route", %{"route_id" => route["id"]})

    assert response.isError == false
    assert response.structured_content["data"]["deleted"] == true
    assert response.structured_content["data"]["route_id"] == route["id"]
    assert {:error, :not_found} = Db.get_route(route["id"], true)
  end

  test "get_route_analytics accepts time window and returns JSON-safe payload" do
    route = route_fixture()

    assert {:ok, response} =
             ToolRegistry.dispatch("get_route_analytics", %{
               "route_id" => route["id"],
               "window" => "last_hour"
             })

    assert response.isError == false

    data = response.structured_content["data"]
    assert data["meta"]["window"] == "last_hour"
    assert is_list(data["points"])
    assert Jason.encode!(response.structured_content)
  end
end

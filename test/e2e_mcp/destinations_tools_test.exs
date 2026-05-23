defmodule HydraSrt.E2E.Mcp.DestinationsToolsTest do
  use HydraSrt.TestSupport.McpE2ECase

  alias HydraSrt.TestSupport.McpE2EClient

  test "list_destinations", %{client: client, ctx: ctx} do
    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "list_destinations", %{"route_id" => ctx.route_id})
      )

    assert is_list(structured["data"])
    assert Enum.any?(structured["data"], &(&1["id"] == ctx.destination_id))
  end

  test "get_destination", %{client: client, ctx: ctx} do
    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "get_destination", %{
          "route_id" => ctx.route_id,
          "destination_id" => ctx.destination_id
        })
      )

    assert structured["data"]["id"] == ctx.destination_id
  end

  test "create_destination", %{client: client, ctx: ctx} do
    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "create_destination", %{
          "route_id" => ctx.route_id,
          "destination" => %{
            "name" => "mcp-e2e-created-destination-#{ctx.suffix}",
            "schema" => "UDP",
            "host" => "127.0.0.1",
            "port" => 32_000 + rem(System.unique_integer([:positive]), 20_000),
            "enabled" => true
          }
        })
      )

    assert structured["data"]["name"] == "mcp-e2e-created-destination-#{ctx.suffix}"
  end

  test "update_destination", %{client: client, ctx: ctx} do
    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "update_destination", %{
          "route_id" => ctx.route_id,
          "destination_id" => ctx.destination_id,
          "destination" => %{"name" => "mcp-e2e-updated-destination-#{ctx.suffix}"}
        })
      )

    assert structured["data"]["name"] == "mcp-e2e-updated-destination-#{ctx.suffix}"
  end

  test "delete_destination", %{client: client, ctx: ctx} do
    {:ok, created} =
      McpE2EClient.call_tool(client, "create_destination", %{
        "route_id" => ctx.route_id,
        "destination" => %{
          "name" => "mcp-e2e-delete-destination-#{ctx.suffix}",
          "schema" => "UDP",
          "host" => "127.0.0.1",
          "port" => 42_000 + rem(System.unique_integer([:positive]), 20_000),
          "enabled" => true
        }
      })

    destination_id = McpAssertions.assert_tool_success({:ok, created})["data"]["id"]

    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "delete_destination", %{
          "route_id" => ctx.route_id,
          "destination_id" => destination_id
        })
      )

    assert structured["data"]["deleted"] == true
    assert structured["data"]["destination_id"] == destination_id
  end
end

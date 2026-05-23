defmodule HydraSrt.E2E.Mcp.RoutesToolsTest do
  use HydraSrt.TestSupport.McpE2ECase

  alias HydraSrt.TestSupport.McpE2EClient

  test "list_routes", %{client: client} do
    McpAssertions.assert_tool_success(McpE2EClient.call_tool(client, "list_routes", %{}))
  end

  test "create_route", %{client: client, ctx: ctx} do
    name = McpFixtures.disposable_route_name(ctx)

    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "create_route", %{
          "route" => %{"name" => name, "alias" => "mcp e2e", "enabled" => false}
        })
      )

    assert structured["data"]["name"] == name
  end

  test "get_route", %{client: client, ctx: ctx} do
    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "get_route", %{"route_id" => ctx.route_id})
      )

    assert structured["data"]["id"] == ctx.route_id
  end

  test "update_route", %{client: client, ctx: ctx} do
    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "update_route", %{
          "route_id" => ctx.route_id,
          "route" => %{"name" => "mcp-e2e-updated-#{ctx.suffix}", "enabled" => false}
        })
      )

    assert structured["data"]["name"] == "mcp-e2e-updated-#{ctx.suffix}"
  end

  test "start_route returns structured MCP response", %{client: client, ctx: ctx} do
    McpAssertions.assert_tool_responds(
      McpE2EClient.call_tool(client, "start_route", %{"route_id" => ctx.route_id},
        timeout: 30_000
      )
    )
  end

  test "stop_route returns structured MCP response", %{client: client, ctx: ctx} do
    McpAssertions.assert_tool_responds(
      McpE2EClient.call_tool(client, "stop_route", %{"route_id" => ctx.route_id}, timeout: 30_000)
    )
  end

  test "restart_route returns structured MCP response", %{client: client, ctx: ctx} do
    McpAssertions.assert_tool_responds(
      McpE2EClient.call_tool(client, "restart_route", %{"route_id" => ctx.route_id},
        timeout: 30_000
      )
    )
  end

  test "switch_route_source returns structured MCP response", %{client: client, ctx: ctx} do
    McpAssertions.assert_tool_responds(
      McpE2EClient.call_tool(client, "switch_route_source", %{
        "route_id" => ctx.route_id,
        "source_id" => ctx.source2_id
      })
    )
  end

  test "delete_route", %{client: client, ctx: ctx} do
    {:ok, created} =
      McpE2EClient.call_tool(client, "create_route", %{
        "route" => %{
          "name" => McpFixtures.disposable_route_name(ctx),
          "alias" => "delete me",
          "enabled" => false
        }
      })

    route_id = McpAssertions.assert_tool_success({:ok, created})["data"]["id"]

    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "delete_route", %{"route_id" => route_id})
      )

    assert structured["data"]["deleted"] == true
    assert structured["data"]["route_id"] == route_id
  end
end

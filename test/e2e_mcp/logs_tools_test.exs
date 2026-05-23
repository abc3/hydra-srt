defmodule HydraSrt.E2E.Mcp.LogsToolsTest do
  use HydraSrt.TestSupport.McpE2ECase

  alias HydraSrt.TestSupport.McpE2EClient

  test "get_route_events", %{client: client, ctx: ctx} do
    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "get_route_events", %{
          "route_id" => ctx.route_id,
          "window" => "last_hour"
        })
      )

    assert is_list(structured["data"]["events"])
    assert is_map(structured["data"]["meta"])
  end

  test "get_route_pipeline_logs", %{client: client, ctx: ctx} do
    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "get_route_pipeline_logs", %{
          "route_id" => ctx.route_id,
          "window" => "last_hour"
        })
      )

    assert is_list(structured["data"]["logs"])
    assert is_map(structured["data"]["meta"])
  end

  test "get_route_pipeline_log_distinct", %{client: client, ctx: ctx} do
    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "get_route_pipeline_log_distinct", %{
          "route_id" => ctx.route_id,
          "column" => "level"
        })
      )

    assert is_list(structured["data"])
  end

  test "get_routes_status_history", %{client: client, ctx: ctx} do
    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "get_routes_status_history", %{
          "window" => "last_hour",
          "route_id" => ctx.route_id
        })
      )

    assert is_list(structured["data"]["events"])
    assert is_map(structured["data"]["meta"])
  end

  test "get_route_analytics", %{client: client, ctx: ctx} do
    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "get_route_analytics", %{
          "route_id" => ctx.route_id,
          "window" => "last_hour"
        })
      )

    assert structured["data"]["meta"]["window"] == "last_hour"
    assert is_list(structured["data"]["points"])
  end

  test "get_routes_status_analytics", %{client: client} do
    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "get_routes_status_analytics", %{"window" => "last_hour"})
      )

    assert structured["data"]["meta"]["window"] == "last_hour"
    assert is_list(structured["data"]["points"])
  end
end

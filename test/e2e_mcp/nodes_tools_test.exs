defmodule HydraSrt.E2E.Mcp.NodesToolsTest do
  use HydraSrt.TestSupport.McpE2ECase

  alias HydraSrt.TestSupport.McpE2EClient

  test "list_nodes", %{client: client} do
    structured =
      McpAssertions.assert_tool_success(McpE2EClient.call_tool(client, "list_nodes", %{}))

    assert is_list(structured["data"])
    assert structured["data"] != []
  end

  test "get_self_node", %{client: client} do
    structured =
      McpAssertions.assert_tool_success(McpE2EClient.call_tool(client, "get_self_node", %{}))

    assert is_map(structured["data"])
    assert Map.has_key?(structured["data"], "host")
  end

  test "get_node_analytics", %{client: client, ctx: ctx} do
    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "get_node_analytics", %{
          "node_id" => ctx.node_id,
          "window" => "last_hour"
        })
      )

    assert structured["data"]["meta"]["window"] == "last_hour"
    assert is_list(structured["data"]["points"])
  end
end

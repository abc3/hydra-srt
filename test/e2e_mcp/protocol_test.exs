defmodule HydraSrt.E2E.Mcp.ProtocolTest do
  use HydraSrt.TestSupport.McpE2ECase

  alias HydraSrt.Mcp.ToolRegistry
  alias HydraSrt.TestSupport.McpE2EClient

  test "ping returns pong", %{client: client} do
    assert :pong = McpE2EClient.ping(client, timeout: 5_000)
  end

  test "list_tools returns all curated tools", %{client: client} do
    assert {:ok, response} = McpE2EClient.list_tools(client, timeout: 10_000)

    result = Hermes.MCP.Response.unwrap(response)
    tool_names = result["tools"] |> Enum.map(& &1["name"]) |> Enum.sort()

    assert tool_names == ToolRegistry.tool_names()
    assert length(tool_names) == 43
  end
end

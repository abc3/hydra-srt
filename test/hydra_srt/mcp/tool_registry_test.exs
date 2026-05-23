defmodule HydraSrt.Mcp.ToolRegistryTest do
  use HydraSrt.DataCase, async: false

  alias HydraSrt.Mcp.ToolRegistry

  @expected_tool_count 43

  test "registers 43 curated tools" do
    assert length(ToolRegistry.tool_names()) == @expected_tool_count
    assert "list_routes" in ToolRegistry.tool_names()
    assert "get_self_node" in ToolRegistry.tool_names()
    assert "get_system_interface" in ToolRegistry.tool_names()
  end

  test "unknown tool returns structured error response" do
    assert {:ok, response} = ToolRegistry.dispatch("not_a_real_tool", %{})
    assert response.isError == true
    assert response.structured_content == %{"error" => "Unknown tool: not_a_real_tool"}
  end

  test "list_tags returns data envelope" do
    assert {:ok, response} = ToolRegistry.dispatch("list_tags", %{})
    assert response.isError == false
    assert is_list(response.structured_content["data"])
  end

  test "get_self_node wraps local node stats in data" do
    assert {:ok, response} = ToolRegistry.dispatch("get_self_node", %{})
    assert response.isError == false
    assert is_map(response.structured_content["data"])
    assert Map.has_key?(response.structured_content["data"], "host")
  end

  test "missing required route_id returns structured error" do
    assert {:ok, response} = ToolRegistry.dispatch("list_sources", %{})
    assert response.isError == true
    assert response.structured_content["error"] =~ "route_id"
  end
end

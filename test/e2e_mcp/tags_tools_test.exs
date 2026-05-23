defmodule HydraSrt.E2E.Mcp.TagsToolsTest do
  use HydraSrt.TestSupport.McpE2ECase

  alias HydraSrt.TestSupport.McpE2EClient

  test "list_tags", %{client: client, ctx: ctx} do
    structured =
      McpAssertions.assert_tool_success(McpE2EClient.call_tool(client, "list_tags", %{}))

    assert is_list(structured["data"])
    assert Enum.any?(structured["data"], &(&1["id"] == ctx.tag_id))
  end

  test "create_tag", %{client: client, ctx: ctx} do
    name = McpFixtures.disposable_tag_name(ctx)

    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "create_tag", %{"tag" => %{"name" => name}})
      )

    assert structured["data"]["name"] == name
  end

  test "update_tag", %{client: client, ctx: ctx} do
    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "update_tag", %{
          "tag_id" => ctx.tag_id,
          "tag" => %{"name" => "mcp-e2e-updated-tag-#{ctx.suffix}"}
        })
      )

    assert structured["data"]["name"] == "mcp-e2e-updated-tag-#{ctx.suffix}"
  end

  test "delete_tag", %{client: client, ctx: ctx} do
    {:ok, created} =
      McpE2EClient.call_tool(client, "create_tag", %{
        "tag" => %{"name" => McpFixtures.disposable_tag_name(ctx)}
      })

    tag_id = McpAssertions.assert_tool_success({:ok, created})["data"]["id"]

    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "delete_tag", %{"tag_id" => tag_id})
      )

    assert structured["data"]["deleted"] == true
    assert structured["data"]["tag_id"] == tag_id
  end
end

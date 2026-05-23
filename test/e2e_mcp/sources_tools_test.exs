defmodule HydraSrt.E2E.Mcp.SourcesToolsTest do
  use HydraSrt.TestSupport.McpE2ECase

  alias HydraSrt.TestSupport.McpE2EClient

  test "list_sources", %{client: client, ctx: ctx} do
    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "list_sources", %{"route_id" => ctx.route_id})
      )

    assert is_list(structured["data"])
    assert Enum.any?(structured["data"], &(&1["id"] == ctx.source_id))
  end

  test "get_source", %{client: client, ctx: ctx} do
    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "get_source", %{
          "route_id" => ctx.route_id,
          "source_id" => ctx.source_id
        })
      )

    assert structured["data"]["id"] == ctx.source_id
  end

  test "create_source", %{client: client, ctx: ctx} do
    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "create_source", %{
          "route_id" => ctx.route_id,
          "source" => %{
            "name" => "mcp-e2e-created-source-#{ctx.suffix}",
            "schema" => "UDP",
            "host" => "127.0.0.1",
            "port" => 12_000 + rem(System.unique_integer([:positive]), 20_000),
            "enabled" => true,
            "position" => 2
          }
        })
      )

    assert structured["data"]["name"] == "mcp-e2e-created-source-#{ctx.suffix}"
  end

  test "update_source", %{client: client, ctx: ctx} do
    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "update_source", %{
          "route_id" => ctx.route_id,
          "source_id" => ctx.source_id,
          "source" => %{"name" => "mcp-e2e-updated-source-#{ctx.suffix}"}
        })
      )

    assert structured["data"]["name"] == "mcp-e2e-updated-source-#{ctx.suffix}"
  end

  test "reorder_sources", %{client: client, ctx: ctx} do
    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "reorder_sources", %{
          "route_id" => ctx.route_id,
          "source_ids" => [ctx.source2_id, ctx.source_id]
        })
      )

    assert is_list(structured["data"])
  end

  test "delete_source", %{client: client, ctx: ctx} do
    {:ok, created} =
      McpE2EClient.call_tool(client, "create_source", %{
        "route_id" => ctx.route_id,
        "source" => %{
          "name" => "mcp-e2e-delete-source-#{ctx.suffix}",
          "schema" => "UDP",
          "host" => "127.0.0.1",
          "port" => 22_000 + rem(System.unique_integer([:positive]), 20_000),
          "enabled" => true,
          "position" => 3
        }
      })

    source_id = McpAssertions.assert_tool_success({:ok, created})["data"]["id"]

    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "delete_source", %{
          "route_id" => ctx.route_id,
          "source_id" => source_id
        })
      )

    assert structured["data"]["deleted"] == true
    assert structured["data"]["source_id"] == source_id
  end
end

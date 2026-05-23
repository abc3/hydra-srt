defmodule HydraSrt.E2E.Mcp.InterfacesToolsTest do
  use HydraSrt.TestSupport.McpE2ECase

  alias HydraSrt.TestSupport.McpE2EClient

  test "list_interfaces", %{client: client, ctx: ctx} do
    structured =
      McpAssertions.assert_tool_success(McpE2EClient.call_tool(client, "list_interfaces", %{}))

    assert is_list(structured["data"])
    assert Enum.any?(structured["data"], &(&1["id"] == ctx.interface_id))
  end

  test "get_interface", %{client: client, ctx: ctx} do
    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "get_interface", %{"interface_id" => ctx.interface_id})
      )

    assert structured["data"]["id"] == ctx.interface_id
  end

  test "create_interface", %{client: client, ctx: ctx} do
    name = McpFixtures.disposable_interface_name(ctx)

    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "create_interface", %{
          "interface" => %{
            "name" => name,
            "sys_name" => "mcp-e2e-sys-#{ctx.suffix}",
            "ip" => "127.0.0.2",
            "enabled" => true
          }
        })
      )

    assert structured["data"]["name"] == name
  end

  test "update_interface", %{client: client, ctx: ctx} do
    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "update_interface", %{
          "interface_id" => ctx.interface_id,
          "interface" => %{"name" => "mcp-e2e-updated-interface-#{ctx.suffix}"}
        })
      )

    assert structured["data"]["name"] == "mcp-e2e-updated-interface-#{ctx.suffix}"
  end

  test "delete_interface", %{client: client, ctx: ctx} do
    {:ok, created} =
      McpE2EClient.call_tool(client, "create_interface", %{
        "interface" => %{
          "name" => McpFixtures.disposable_interface_name(ctx),
          "sys_name" => "mcp-e2e-delete-sys-#{ctx.suffix}",
          "ip" => "127.0.0.3",
          "enabled" => true
        }
      })

    interface_id = McpAssertions.assert_tool_success({:ok, created})["data"]["id"]

    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "delete_interface", %{"interface_id" => interface_id})
      )

    assert structured["data"]["deleted"] == true
    assert structured["data"]["interface_id"] == interface_id
  end

  test "list_system_interfaces", %{client: client} do
    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "list_system_interfaces", %{})
      )

    assert is_list(structured["data"])
  end

  test "get_system_interface", %{client: client, ctx: ctx} do
    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "get_system_interface", %{
          "sys_name" => ctx.loopback_sys_name
        })
      )

    assert structured["data"]["sys_name"] == ctx.loopback_sys_name
  end

  test "get_system_interfaces_raw", %{client: client} do
    structured =
      McpAssertions.assert_tool_success(
        McpE2EClient.call_tool(client, "get_system_interfaces_raw", %{})
      )

    assert is_binary(structured["data"]["raw"])
    assert structured["data"]["raw"] != ""
  end
end

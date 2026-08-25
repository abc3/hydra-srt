defmodule HydraSrt.E2E.Mcp.ProbesToolsTest do
  use HydraSrt.TestSupport.McpE2EProbeCase

  alias HydraSrt.TestSupport.McpE2EClient

  @probe_timeout 20_000

  test "test_route_source returns structured MCP response for unreachable UDP source", %{
    client: client,
    ctx: ctx
  } do
    port = E2EHelpers.udp_free_port!()

    McpAssertions.assert_tool_responds(
      McpE2EClient.call_tool(
        client,
        "test_route_source",
        %{
          "route" => %{
            "name" => "mcp-e2e-probe-route-#{ctx.suffix}",
            "source" => %{
              "schema" => "UDP",
              "host" => "127.0.0.1",
              "port" => port
            }
          }
        },
        timeout: @probe_timeout
      )
    )
  end

  test "test_source returns structured MCP response for unreachable saved source", %{
    client: client,
    ctx: ctx
  } do
    {:ok, created} =
      McpE2EClient.call_tool(client, "create_source", %{
        "route_id" => ctx.route_id,
        "source" => %{
          "name" => "mcp-e2e-probe-source-#{ctx.suffix}",
          "schema" => "UDP",
          "host" => "127.0.0.1",
          "port" => E2EHelpers.udp_free_port!(),
          "enabled" => true,
          "position" => 4
        }
      })

    source_id = McpAssertions.assert_tool_success({:ok, created})["data"]["id"]

    McpAssertions.assert_tool_responds(
      McpE2EClient.call_tool(
        client,
        "test_source",
        %{"route_id" => ctx.route_id, "source_id" => source_id},
        timeout: @probe_timeout
      )
    )
  end
end

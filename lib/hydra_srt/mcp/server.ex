defmodule HydraSrt.Mcp.Server do
  @moduledoc """
  MCP server for Hydra SRT.
  """
  alias HydraSrt.Mcp.ToolRegistry

  use Hermes.Server,
    name: "HydraSRT MCP",
    version: "1.0.0",
    capabilities: [:tools]

  @impl true
  def init(_client_info, frame) do
    {:ok, ToolRegistry.register_all(frame)}
  end

  @impl true
  def handle_tool_call(name, args, frame) do
    {:ok, response} = ToolRegistry.dispatch(name, args)
    {:reply, response, frame}
  end
end

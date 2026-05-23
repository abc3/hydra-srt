defmodule HydraSrt.Mcp.Server do
  @moduledoc """
  MCP server for Hydra SRT.
  """
  alias HydraSrt.Db
  alias Hermes.Server.Response

  use Hermes.Server,
    name: "HydraSRT MCP",
    version: "1.0.0",
    capabilities: [:tools]

  @impl true
  def init(_client_info, frame) do
    {:ok,
     register_tool(frame, "list_routes",
       description: "Return Hydra routes data from /api/routes",
       input_schema: %{}
     )}
  end

  @impl true
  def handle_tool_call("list_routes", _args, frame) do
    {:ok, payload} = Db.get_routes_page(true, "created_at", 1, 500)

    response =
      Response.tool()
      |> Response.structured(%{
        "data" => payload.routes,
        "meta" => %{
          "page" => payload.page,
          "limit" => payload.limit,
          "total" => payload.total
        }
      })

    {:reply, response, frame}
  end
end

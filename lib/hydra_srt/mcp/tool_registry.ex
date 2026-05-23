defmodule HydraSrt.Mcp.ToolRegistry do
  @moduledoc false

  alias HydraSrt.Mcp.Helpers
  alias HydraSrt.Mcp.Tools.Destinations
  alias HydraSrt.Mcp.Tools.Interfaces
  alias HydraSrt.Mcp.Tools.Logs
  alias HydraSrt.Mcp.Tools.Nodes
  alias HydraSrt.Mcp.Tools.Routes
  alias HydraSrt.Mcp.Tools.Sources
  alias HydraSrt.Mcp.Tools.Tags

  @tool_modules [
    Routes,
    Sources,
    Destinations,
    Tags,
    Interfaces,
    Nodes,
    Logs
  ]

  @spec tool_modules() :: [module()]
  def tool_modules, do: @tool_modules

  @spec tool_names() :: [String.t()]
  def tool_names do
    definitions()
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  @spec definitions() :: [map()]
  def definitions do
    Enum.flat_map(@tool_modules, & &1.definitions())
  end

  @spec register_all(term()) :: term()
  def register_all(frame) do
    Enum.reduce(definitions(), frame, fn definition, acc_frame ->
      Hermes.Server.Frame.register_tool(acc_frame, definition.name,
        description: definition.description,
        input_schema: definition.input_schema
      )
    end)
  end

  @spec dispatch(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def dispatch(name, args) when is_binary(name) and is_map(args) do
    case find_module(name) do
      {:ok, module} ->
        case module.call(name, args) do
          :unknown -> {:ok, Helpers.unknown_tool(name)}
          {:ok, response} -> {:ok, response}
          {:error, response} -> {:ok, response}
        end

      :error ->
        {:ok, Helpers.unknown_tool(name)}
    end
  end

  @spec find_module(String.t()) :: {:ok, module()} | :error
  def find_module(name) when is_binary(name) do
    case Enum.find(@tool_modules, & &1.handles?(name)) do
      nil -> :error
      module -> {:ok, module}
    end
  end
end

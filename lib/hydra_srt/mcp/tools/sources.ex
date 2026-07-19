defmodule HydraSrt.Mcp.Tools.Sources do
  @moduledoc false

  alias HydraSrt.Mcp.Helpers
  alias HydraSrt.Mcp.InputSchema
  alias HydraSrt.Mcp.Tools.Routes, as: Schema
  alias HydraSrt.Sources

  @spec definitions() :: [map()]
  def definitions do
    route_id = Schema.string_prop("Route ID")
    source_attrs = InputSchema.source_attributes_schema()

    [
      %{
        name: "list_sources",
        description: "List sources for a route.",
        input_schema: Schema.object_schema(%{"route_id" => route_id}, ["route_id"])
      },
      %{
        name: "get_source",
        description: "Get a source by ID within a route.",
        input_schema:
          Schema.object_schema(
            %{"route_id" => route_id, "source_id" => Schema.string_prop("Source ID")},
            ["route_id", "source_id"]
          )
      },
      %{
        name: "create_source",
        description: "Create a source on a route.",
        input_schema:
          Schema.object_schema(
            %{"route_id" => route_id, "source" => source_attrs},
            ["route_id", "source"]
          )
      },
      %{
        name: "update_source",
        description: "Update a source on a route.",
        input_schema:
          Schema.object_schema(
            %{
              "route_id" => route_id,
              "source_id" => Schema.string_prop("Source ID"),
              "source" => source_attrs
            },
            ["route_id", "source_id", "source"]
          )
      },
      %{
        name: "delete_source",
        description: "Delete a source from a route.",
        input_schema:
          Schema.object_schema(
            %{"route_id" => route_id, "source_id" => Schema.string_prop("Source ID")},
            ["route_id", "source_id"]
          )
      },
      %{
        name: "reorder_sources",
        description: "Reorder sources on a route.",
        input_schema:
          Schema.object_schema(
            %{
              "route_id" => route_id,
              "source_ids" => Schema.array_prop("Ordered list of source IDs")
            },
            ["route_id", "source_ids"]
          )
      },
      %{
        name: "test_source",
        description: "Test a saved source with ffprobe." <> Helpers.probe_description_suffix(),
        input_schema:
          Schema.object_schema(
            %{"route_id" => route_id, "source_id" => Schema.string_prop("Source ID")},
            ["route_id", "source_id"]
          )
      }
    ]
  end

  @spec handles?(String.t()) :: boolean()
  def handles?(name), do: name in Enum.map(definitions(), & &1.name)

  @spec call(String.t(), map()) :: {:ok, term()} | {:error, term()} | :unknown
  def call("list_sources", args) do
    with {:ok, route_id} <- Schema.param(args, "route_id"),
         result <- Sources.list(route_id) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call("get_source", args) do
    with {:ok, route_id} <- Schema.param(args, "route_id"),
         {:ok, source_id} <- Schema.param(args, "source_id"),
         result <- Sources.get(route_id, source_id) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call("create_source", args) do
    with {:ok, route_id} <- Schema.param(args, "route_id"),
         {:ok, source} <- Schema.map_param(args, "source"),
         result <- Sources.create(route_id, InputSchema.sanitize_source_attrs(source)) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call("update_source", args) do
    with {:ok, route_id} <- Schema.param(args, "route_id"),
         {:ok, source_id} <- Schema.param(args, "source_id"),
         {:ok, source} <- Schema.map_param(args, "source"),
         result <-
           Sources.update(route_id, source_id, InputSchema.sanitize_source_attrs(source)) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call("delete_source", args) do
    with {:ok, route_id} <- Schema.param(args, "route_id"),
         {:ok, source_id} <- Schema.param(args, "source_id") do
      case Sources.delete(route_id, source_id) do
        :ok ->
          {:ok,
           Helpers.ok(%{"deleted" => true, "route_id" => route_id, "source_id" => source_id})}

        other ->
          {:ok, Helpers.from_result(other)}
      end
    end
  end

  def call("reorder_sources", args) do
    with {:ok, route_id} <- Schema.param(args, "route_id"),
         {:ok, source_ids} <- require_source_ids(args),
         result <- Sources.reorder(route_id, source_ids) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call("test_source", args) do
    with {:ok, route_id} <- Schema.param(args, "route_id"),
         {:ok, source_id} <- Schema.param(args, "source_id"),
         result <-
           Sources.test(route_id, source_id, timeout_ms: Helpers.probe_timeout_ms()) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call(_name, _args), do: :unknown

  @spec require_source_ids(map()) :: {:ok, [term()]} | {:error, term()}
  def require_source_ids(args) do
    case Map.get(args, "source_ids") do
      ids when is_list(ids) -> {:ok, ids}
      _ -> {:error, Helpers.error_response("Missing required 'source_ids' parameter")}
    end
  end
end

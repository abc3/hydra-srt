defmodule HydraSrt.Mcp.Tools.Destinations do
  @moduledoc false

  alias HydraSrt.Destinations
  alias HydraSrt.Mcp.Helpers
  alias HydraSrt.Mcp.InputSchema
  alias HydraSrt.Mcp.Tools.Routes, as: Schema

  @spec definitions() :: [map()]
  def definitions do
    route_id = Schema.string_prop("Route ID")
    destination_attrs = InputSchema.destination_attributes_schema()

    [
      %{
        name: "list_destinations",
        description: "List destinations for a route.",
        input_schema: Schema.object_schema(%{"route_id" => route_id}, ["route_id"])
      },
      %{
        name: "get_destination",
        description: "Get a destination by ID within a route.",
        input_schema:
          Schema.object_schema(
            %{
              "route_id" => route_id,
              "destination_id" => Schema.string_prop("Destination ID")
            },
            ["route_id", "destination_id"]
          )
      },
      %{
        name: "create_destination",
        description: "Create a destination on a route.",
        input_schema:
          Schema.object_schema(
            %{
              "route_id" => route_id,
              "destination" => destination_attrs
            },
            ["route_id", "destination"]
          )
      },
      %{
        name: "update_destination",
        description: "Update a destination on a route.",
        input_schema:
          Schema.object_schema(
            %{
              "route_id" => route_id,
              "destination_id" => Schema.string_prop("Destination ID"),
              "destination" => destination_attrs
            },
            ["route_id", "destination_id", "destination"]
          )
      },
      %{
        name: "delete_destination",
        description: "Delete a destination from a route.",
        input_schema:
          Schema.object_schema(
            %{
              "route_id" => route_id,
              "destination_id" => Schema.string_prop("Destination ID")
            },
            ["route_id", "destination_id"]
          )
      }
    ]
  end

  @spec handles?(String.t()) :: boolean()
  def handles?(name), do: name in Enum.map(definitions(), & &1.name)

  @spec call(String.t(), map()) :: {:ok, term()} | {:error, term()} | :unknown
  def call("list_destinations", args) do
    with {:ok, route_id} <- Schema.param(args, "route_id"),
         result <- Destinations.list(route_id) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call("get_destination", args) do
    with {:ok, route_id} <- Schema.param(args, "route_id"),
         {:ok, destination_id} <- Schema.param(args, "destination_id"),
         result <- Destinations.get(route_id, destination_id) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call("create_destination", args) do
    with {:ok, route_id} <- Schema.param(args, "route_id"),
         {:ok, destination} <- Schema.map_param(args, "destination"),
         result <-
           Destinations.create(
             route_id,
             InputSchema.sanitize_destination_attrs(destination)
           ) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call("update_destination", args) do
    with {:ok, route_id} <- Schema.param(args, "route_id"),
         {:ok, destination_id} <- Schema.param(args, "destination_id"),
         {:ok, destination} <- Schema.map_param(args, "destination"),
         result <-
           Destinations.update(
             route_id,
             destination_id,
             InputSchema.sanitize_destination_attrs(destination)
           ) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call("delete_destination", args) do
    with {:ok, route_id} <- Schema.param(args, "route_id"),
         {:ok, destination_id} <- Schema.param(args, "destination_id") do
      case Destinations.delete(route_id, destination_id) do
        :ok ->
          {:ok,
           Helpers.ok(%{
             "deleted" => true,
             "route_id" => route_id,
             "destination_id" => destination_id
           })}

        other ->
          {:ok, Helpers.from_result(other)}
      end
    end
  end

  def call(_name, _args), do: :unknown
end

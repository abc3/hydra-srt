defmodule HydraSrt.Mcp.Tools.Routes do
  @moduledoc false

  alias HydraSrt.Mcp.Helpers
  alias HydraSrt.Routes

  @spec definitions() :: [map()]
  def definitions do
    [
      %{
        name: "list_routes",
        description: "List routes with optional pagination (same data as GET /api/routes).",
        input_schema:
          object_schema(%{
            "page" => integer_prop("Page number (default 1)"),
            "limit" => integer_prop("Page size, max 500 (default 50)"),
            "sort_by" =>
              enum_prop(["created_at", "updated_at"], "Sort field (default created_at)")
          })
      },
      %{
        name: "get_route",
        description: "Get a route by ID including sources and destinations.",
        input_schema: object_schema(%{"route_id" => string_prop("Route ID")}, ["route_id"])
      },
      %{
        name: "create_route",
        description: "Create a route (POST /api/routes).",
        input_schema: object_schema(%{"route" => object_prop("Route attributes")}, ["route"])
      },
      %{
        name: "update_route",
        description: "Update a route (PUT /api/routes/:id). Runtime status fields are ignored.",
        input_schema:
          object_schema(
            %{
              "route_id" => string_prop("Route ID"),
              "route" => object_prop("Route attributes")
            },
            ["route_id", "route"]
          )
      },
      %{
        name: "delete_route",
        description: "Delete a route (DELETE /api/routes/:id).",
        input_schema: object_schema(%{"route_id" => string_prop("Route ID")}, ["route_id"])
      },
      %{
        name: "start_route",
        description: "Start a route pipeline (GET /api/routes/:id/start).",
        input_schema: object_schema(%{"route_id" => string_prop("Route ID")}, ["route_id"])
      },
      %{
        name: "stop_route",
        description: "Stop a route pipeline (GET /api/routes/:id/stop).",
        input_schema: object_schema(%{"route_id" => string_prop("Route ID")}, ["route_id"])
      },
      %{
        name: "restart_route",
        description: "Restart a route pipeline (GET /api/routes/:id/restart).",
        input_schema: object_schema(%{"route_id" => string_prop("Route ID")}, ["route_id"])
      },
      %{
        name: "switch_route_source",
        description: "Switch active source for a route (POST /api/routes/:id/switch-source).",
        input_schema:
          object_schema(
            %{
              "route_id" => string_prop("Route ID"),
              "source_id" => string_prop("Source ID to activate")
            },
            ["route_id", "source_id"]
          )
      },
      %{
        name: "test_route_source",
        description:
          "Test a route source configuration with ffprobe." <> Helpers.probe_description_suffix(),
        input_schema:
          object_schema(%{"route" => object_prop("Route/source attributes")}, ["route"])
      }
    ]
  end

  @spec handles?(String.t()) :: boolean()
  def handles?(name), do: name in Enum.map(definitions(), & &1.name)

  @spec call(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call("list_routes", args) do
    case Routes.list_page(args) do
      {:ok, payload} ->
        {:ok,
         Helpers.ok_with_meta(payload.routes, %{
           "page" => payload.page,
           "limit" => payload.limit,
           "total" => payload.total
         })}

      error ->
        {:ok, Helpers.from_result(error)}
    end
  end

  def call("get_route", args) do
    with {:ok, route_id} <- param(args, "route_id"),
         result <- Routes.get(route_id) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call("create_route", args) do
    with {:ok, route} <- map_param(args, "route"),
         result <- Routes.create(route) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call("update_route", args) do
    with {:ok, route_id} <- param(args, "route_id"),
         {:ok, route} <- map_param(args, "route"),
         result <- Routes.update(route_id, route) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call("delete_route", args) do
    with {:ok, route_id} <- param(args, "route_id") do
      case Routes.delete(route_id) do
        :ok -> {:ok, Helpers.ok(%{"deleted" => true, "route_id" => route_id})}
        error -> {:ok, Helpers.from_result(error)}
      end
    end
  end

  def call("start_route", args) do
    with {:ok, route_id} <- param(args, "route_id"),
         result <- Routes.start(route_id) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call("stop_route", args) do
    with {:ok, route_id} <- param(args, "route_id"),
         result <- Routes.stop(route_id) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call("restart_route", args) do
    with {:ok, route_id} <- param(args, "route_id"),
         result <- Routes.restart(route_id) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call("switch_route_source", args) do
    with {:ok, route_id} <- param(args, "route_id"),
         {:ok, source_id} <- param(args, "source_id"),
         result <- Routes.switch_source(route_id, source_id) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call("test_route_source", args) do
    with {:ok, route} <- map_param(args, "route"),
         result <-
           Routes.test_source_config(route, timeout_ms: Helpers.probe_timeout_ms()) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call(_name, _args), do: :unknown

  def object_schema(properties, required \\ []) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => required
    }
  end

  def string_prop(description), do: %{"type" => "string", "description" => description}

  def integer_prop(description), do: %{"type" => "integer", "description" => description}

  def object_prop(description), do: %{"type" => "object", "description" => description}

  def enum_prop(values, description) do
    %{"type" => "string", "enum" => values, "description" => description}
  end

  def array_prop(description) do
    %{"type" => "array", "items" => %{"type" => "string"}, "description" => description}
  end

  def param(args, key) do
    case Helpers.require_param(args, key) do
      {:ok, value} -> {:ok, value}
      {:error, response} -> {:error, response}
    end
  end

  def map_param(args, key) do
    case Helpers.require_map_param(args, key) do
      {:ok, value} -> {:ok, value}
      {:error, response} -> {:error, response}
    end
  end
end

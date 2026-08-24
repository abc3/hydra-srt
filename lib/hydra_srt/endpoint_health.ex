defmodule HydraSrt.EndpointHealth do
  @moduledoc """
  Builds the per-route endpoint-health snapshot, across every transport
  (SRT, UDP, RTMP, NDI) the route is configured with.

  Live RouteHandler state is authoritative while a handler exists. When no
  handler is present, records are derived as stopped/unknown from persisted
  endpoints — never a stale healthy projection.
  """

  alias HydraSrt.Db
  alias HydraSrt.RouteHandler

  @type health_record :: %{optional(String.t()) => term()}
  @type snapshot :: %{
          generated_at: String.t(),
          config_revision: String.t() | nil,
          process_instance_id: String.t() | nil,
          last_sequence: non_neg_integer(),
          endpoints: [health_record()]
        }

  @spec snapshot(String.t(), keyword()) :: {:ok, snapshot()} | {:error, :not_found}
  def snapshot(route_id, opts \\ []) when is_binary(route_id) and is_list(opts) do
    lookup_fun = Keyword.get(opts, :lookup_fun, &HydraSrt.get_route_handler/1)
    health_fun = Keyword.get(opts, :health_fun, &RouteHandler.get_endpoint_health/1)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case Db.get_route(route_id, true) do
      {:ok, route} ->
        route_endpoints = saved_route_endpoints(route)

        case lookup_fun.(route_id) do
          {:ok, pid} when is_pid(pid) ->
            case health_fun.(pid) do
              {:ok, identity} ->
                {:ok, live_snapshot(route_endpoints, identity, now)}

              {:error, _reason} ->
                # Fail closed: never invent healthy state when the handler call fails.
                {:ok, stopped_snapshot(route_endpoints, now)}
            end

          {:error, _reason} ->
            {:ok, stopped_snapshot(route_endpoints, now)}
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  # Every configured source/destination gets a row here, regardless of
  # transport - this snapshot is the one truthful, transport-agnostic view of
  # "what is this route's endpoint actually doing right now". It used to be
  # filtered down to NDI endpoints only (from when this module predated the
  # native side reporting SRT/UDP/RTMP endpoint_health at all), which silently
  # dropped every SRT endpoint's live health from this API - the operator saw
  # `endpoints: []` for an SRT route no matter what the pipeline was actually
  # reporting.
  @spec saved_route_endpoints(map()) :: [map()]
  def saved_route_endpoints(route) when is_map(route) do
    sources =
      (route["sources"] || [])
      |> Enum.map(&Map.put(&1, "_direction", "source"))

    destinations =
      (route["destinations"] || [])
      |> Enum.map(&Map.put(&1, "_direction", "destination"))

    sources ++ destinations
  end

  @spec endpoint_transport(map()) :: String.t()
  def endpoint_transport(%{"schema" => schema}) when is_binary(schema),
    do: String.downcase(schema)

  def endpoint_transport(_), do: "unknown"

  @spec live_snapshot([map()], RouteHandler.endpoint_health_identity(), DateTime.t()) ::
          snapshot()
  def live_snapshot(route_endpoints, identity, now)
      when is_list(route_endpoints) and is_map(identity) and is_struct(now, DateTime) do
    health = identity[:endpoint_health] || %{}

    endpoints =
      Enum.map(route_endpoints, fn endpoint ->
        endpoint_id = endpoint["id"]

        case health[endpoint_id] do
          record when is_map(record) ->
            record
            |> Map.put("endpoint_id", endpoint_id)
            |> Map.put_new("direction", endpoint["_direction"])
            |> Map.put_new("transport", endpoint_transport(endpoint))

          _ ->
            derived_record(endpoint, "unknown")
        end
      end)

    %{
      generated_at: iso8601(now),
      config_revision: identity[:config_revision],
      process_instance_id: identity[:process_instance_id],
      last_sequence: identity[:last_sequence] || 0,
      endpoints: endpoints
    }
  end

  @spec stopped_snapshot([map()], DateTime.t()) :: snapshot()
  def stopped_snapshot(route_endpoints, now)
      when is_list(route_endpoints) and is_struct(now, DateTime) do
    endpoints =
      Enum.map(route_endpoints, fn endpoint ->
        state =
          if endpoint["enabled"] == false do
            "disabled"
          else
            "stopped"
          end

        derived_record(endpoint, state)
      end)

    %{
      generated_at: iso8601(now),
      config_revision: nil,
      process_instance_id: nil,
      last_sequence: 0,
      endpoints: endpoints
    }
  end

  @spec derived_record(map(), String.t()) :: health_record()
  def derived_record(endpoint, state) when is_map(endpoint) and is_binary(state) do
    %{
      "endpoint_id" => endpoint["id"],
      "direction" => endpoint["_direction"],
      "transport" => endpoint_transport(endpoint),
      "state" => state,
      "reason_code" => nil,
      "retryable" => nil,
      "retry_domain" => nil,
      "detail" => nil
    }
  end

  @spec iso8601(DateTime.t()) :: String.t()
  def iso8601(%DateTime{} = now) do
    now
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end

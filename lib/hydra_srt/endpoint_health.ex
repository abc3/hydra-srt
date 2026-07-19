defmodule HydraSrt.EndpointHealth do
  @moduledoc """
  Builds the per-route endpoint-health snapshot.

  Live RouteHandler state is authoritative while a handler exists. When no
  handler is present, records are derived as stopped/unknown from persisted
  NDI endpoints — never a stale healthy projection.
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
        ndi_endpoints = saved_ndi_endpoints(route)

        case lookup_fun.(route_id) do
          {:ok, pid} when is_pid(pid) ->
            case health_fun.(pid) do
              {:ok, identity} ->
                {:ok, live_snapshot(ndi_endpoints, identity, now)}

              {:error, _reason} ->
                # Fail closed: never invent healthy state when the handler call fails.
                {:ok, stopped_snapshot(ndi_endpoints, now)}
            end

          {:error, _reason} ->
            {:ok, stopped_snapshot(ndi_endpoints, now)}
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @spec saved_ndi_endpoints(map()) :: [map()]
  def saved_ndi_endpoints(route) when is_map(route) do
    sources =
      (route["sources"] || [])
      |> Enum.filter(&ndi_endpoint?/1)
      |> Enum.map(&Map.put(&1, "_direction", "source"))

    destinations =
      (route["destinations"] || [])
      |> Enum.filter(&ndi_endpoint?/1)
      |> Enum.map(&Map.put(&1, "_direction", "destination"))

    sources ++ destinations
  end

  @spec ndi_endpoint?(term()) :: boolean()
  def ndi_endpoint?(%{"schema" => schema}) when is_binary(schema),
    do: String.upcase(schema) == "NDI"

  def ndi_endpoint?(_), do: false

  @spec live_snapshot([map()], RouteHandler.endpoint_health_identity(), DateTime.t()) ::
          snapshot()
  def live_snapshot(ndi_endpoints, identity, now)
      when is_list(ndi_endpoints) and is_map(identity) and is_struct(now, DateTime) do
    health = identity[:endpoint_health] || %{}

    endpoints =
      Enum.map(ndi_endpoints, fn endpoint ->
        endpoint_id = endpoint["id"]

        case health[endpoint_id] do
          record when is_map(record) ->
            record
            |> Map.put("endpoint_id", endpoint_id)
            |> Map.put_new("direction", endpoint["_direction"])
            |> Map.put_new("transport", "ndi")

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
  def stopped_snapshot(ndi_endpoints, now)
      when is_list(ndi_endpoints) and is_struct(now, DateTime) do
    endpoints =
      Enum.map(ndi_endpoints, fn endpoint ->
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
      "transport" => "ndi",
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

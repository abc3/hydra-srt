defmodule HydraSrtWeb.NdiProbesController do
  @moduledoc """
  Runs a bounded NDI source probe against either a saved source endpoint id or a
  validated unsaved NDI endpoint object. Never mutates active routes.
  """

  use HydraSrtWeb, :controller

  alias HydraSrt.Api
  alias HydraSrt.Api.Endpoint
  alias HydraSrt.Db
  alias HydraSrt.Ndi.FeaturePolicy
  alias HydraSrt.Ndi.Probe

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    case FeaturePolicy.deny_reason(:receive) do
      reason when is_binary(reason) ->
        ndi_error(conn, 424, reason, "NDI receive is disabled")

      nil ->
        case resolve_probe_source(params) do
          {:ok, source, route} ->
            case Probe.run(source, route: route) do
              {:ok, result} ->
                json(conn, %{data: serialize_probe_result(result)})

              {:error, code, message} ->
                ndi_error(conn, status_for_code(code), code, message)
            end

          {:error, code, message, errors} ->
            conn
            |> put_status(status_for_code(code))
            |> json(%{error: message, code: code, errors: errors})
        end
    end
  end

  @spec resolve_probe_source(map()) ::
          {:ok, map(), map()} | {:error, String.t(), String.t(), map()}
  def resolve_probe_source(params) when is_map(params) do
    cond do
      is_binary(params["endpoint_id"]) and params["endpoint_id"] != "" ->
        load_saved_endpoint(params["endpoint_id"])

      is_binary(params["source_id"]) and params["source_id"] != "" ->
        load_saved_endpoint(params["source_id"])

      is_map(params["endpoint"]) ->
        validate_unsaved_endpoint(params["endpoint"])

      is_map(params["source"]) ->
        validate_unsaved_endpoint(params["source"])

      true ->
        {:error, "NDI_CONFIG_INVALID", "Provide endpoint_id or endpoint",
         %{"endpoint" => ["can't be blank"]}}
    end
  end

  @spec load_saved_endpoint(String.t()) ::
          {:ok, map(), map()} | {:error, String.t(), String.t(), map()}
  def load_saved_endpoint(endpoint_id) when is_binary(endpoint_id) do
    case Api.get_source(endpoint_id) do
      %Endpoint{} = endpoint ->
        source = Db.source_to_map(endpoint)

        if source["schema"] == "NDI" do
          route =
            case Db.get_route_map(endpoint.route_id, false, false) do
              map when is_map(map) -> map
              _ -> %{"id" => endpoint.route_id, "name" => "route"}
            end

          {:ok, source, route}
        else
          {:error, "NDI_CONFIG_INVALID", "Endpoint is not an NDI source",
           %{"endpoint_id" => ["must reference an NDI source"]}}
        end

      nil ->
        {:error, "NDI_CONFIG_INVALID", "Endpoint not found",
         %{"endpoint_id" => ["does not exist"]}}
    end
  end

  @spec validate_unsaved_endpoint(map()) ::
          {:ok, map(), map()} | {:error, String.t(), String.t(), map()}
  def validate_unsaved_endpoint(attrs) when is_map(attrs) do
    string_attrs = stringify_param_keys(attrs)

    attrs =
      string_attrs
      |> Map.put("schema", string_attrs["schema"] || "NDI")
      |> Map.put_new("type", "source")
      |> Map.put_new("route_id", Ecto.UUID.generate())
      |> Map.put_new("position", 0)

    changeset = Endpoint.source_changeset(%Endpoint{}, attrs)

    if changeset.valid? do
      source =
        changeset
        |> Ecto.Changeset.apply_changes()
        |> Db.source_to_map()
        |> Map.put("schema", "NDI")
        |> Map.put_new("id", Ecto.UUID.generate())

      route = %{"id" => "unsaved", "name" => source["name"] || "probe"}
      {:ok, source, route}
    else
      errors =
        Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
          Enum.reduce(opts, msg, fn {key, value}, acc ->
            String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
          end)
        end)
        |> Map.new(fn {key, messages} -> {Atom.to_string(key), messages} end)

      {:error, "NDI_CONFIG_INVALID", "Validation failed", errors}
    end
  end

  @spec serialize_probe_result(Probe.probe_result()) :: map()
  def serialize_probe_result(result) when is_map(result) do
    %{
      ok: result.ok,
      code: result.code,
      caps: %{
        video: result.video_caps,
        audio: result.audio_caps
      },
      frames: result.frames,
      skew_ms: result.skew_ms,
      elapsed_ms: result.elapsed_ms,
      probe_instance_id: result.probe_instance_id,
      detail: result.detail
    }
  end

  @spec status_for_code(String.t()) :: pos_integer()
  def status_for_code("NDI_DISABLED"), do: 424
  def status_for_code("NDI_CONFIG_INVALID"), do: 422
  def status_for_code("NDI_PLUGIN_MISSING"), do: 424
  def status_for_code("NDI_RUNTIME_MISSING"), do: 424
  def status_for_code(_code), do: 424

  @spec ndi_error(Plug.Conn.t(), pos_integer(), String.t(), String.t()) :: Plug.Conn.t()
  def ndi_error(conn, status, code, message)
      when is_integer(status) and is_binary(code) and is_binary(message) do
    conn
    |> put_status(status)
    |> json(%{error: message, code: code, errors: %{}})
  end

  @spec stringify_param_keys(map()) :: map()
  def stringify_param_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} when is_binary(key) -> {key, value}
    end)
  end
end

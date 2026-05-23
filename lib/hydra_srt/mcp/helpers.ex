defmodule HydraSrt.Mcp.Helpers do
  @moduledoc false

  alias Hermes.Server.Response

  @spec ok(term()) :: Response.t()
  def ok(data) do
    structured(%{"data" => data})
  end

  @spec ok_with_meta(term(), map()) :: Response.t()
  def ok_with_meta(data, meta) when is_map(meta) do
    structured(%{"data" => data, "meta" => meta})
  end

  @spec structured(map()) :: Response.t()
  def structured(payload) when is_map(payload) do
    Response.tool()
    |> Response.structured(stringify_keys(payload))
  end

  @spec error_response(String.t()) :: Response.t()
  def error_response(message) when is_binary(message) do
    Response.tool()
    |> Response.structured(%{"error" => message})
    |> Map.put(:isError, true)
  end

  @spec error_response(map()) :: Response.t()
  def error_response(payload) when is_map(payload) do
    Response.tool()
    |> Response.structured(stringify_keys(payload))
    |> Map.put(:isError, true)
  end

  @spec unknown_tool(String.t()) :: Response.t()
  def unknown_tool(name) when is_binary(name) do
    error_response("Unknown tool: #{name}")
  end

  @spec from_result({:ok, term()} | {:error, term()}) :: Response.t()
  def from_result({:ok, data}), do: ok(data)

  def from_result({:error, %Ecto.Changeset{} = changeset}) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    error_response(%{"errors" => errors})
  end

  def from_result({:error, :not_found}), do: error_response("Not found")

  def from_result({:error, :source_disabled}),
    do: error_response("Source is disabled")

  def from_result({:error, :route_handler_unavailable}),
    do: error_response("Route handler is unavailable for running route")

  def from_result({:error, :invalid_source_order}),
    do: error_response("Invalid source order")

  def from_result({:error, :active_source_cannot_be_deleted}),
    do: error_response("Active source cannot be deleted")

  def from_result({:error, {:bad_request, message}}) when is_binary(message),
    do: error_response(message)

  def from_result({:error, reason}) when is_binary(reason), do: error_response(reason)

  def from_result({:error, reason}), do: error_response(inspect(reason))

  @spec require_param(map(), String.t()) :: {:ok, term()} | {:error, Response.t()}
  def require_param(args, key) when is_map(args) and is_binary(key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, error_response("Missing required '#{key}' parameter")}
    end
  end

  @spec require_map_param(map(), String.t()) :: {:ok, map()} | {:error, Response.t()}
  def require_map_param(args, key) when is_map(args) and is_binary(key) do
    case Map.get(args, key) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, error_response("Missing required '#{key}' parameter")}
    end
  end

  @spec parse_positive_int(term(), pos_integer()) :: pos_integer()
  def parse_positive_int(value, default),
    do: HydraSrt.Pagination.parse_positive_int(value, default)

  @spec analytics_params(map()) :: map()
  def analytics_params(args) when is_map(args), do: HydraSrt.AnalyticsParams.normalize(args)

  @spec map_with_error({:error, term()}, (term() -> Response.t())) :: {:ok, Response.t()}
  def map_with_error({:error, %{type: :tool} = response}, _handler), do: {:ok, response}

  def map_with_error({:error, reason}, handler) when is_function(handler, 1),
    do: {:ok, handler.(reason)}

  @spec stringify_keys(term()) :: term()
  def stringify_keys(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def stringify_keys(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)

  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_keys(value)}
      {key, value} -> {key, stringify_keys(value)}
    end)
  end

  def stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  def stringify_keys(other), do: other
end

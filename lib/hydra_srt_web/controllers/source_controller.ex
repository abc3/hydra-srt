defmodule HydraSrtWeb.SourceController do
  use HydraSrtWeb, :controller

  alias HydraSrt.SourceNdiSelection
  alias HydraSrt.Sources

  action_fallback HydraSrtWeb.FallbackController

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t() | {:error, term()}
  def index(conn, %{"route_id" => route_id}) do
    with {:ok, sources} <- Sources.list(route_id) do
      data(conn, sources)
    end
  end

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t() | {:error, term()}
  def create(conn, %{"source" => source_params, "route_id" => route_id}) do
    with {:ok, source_params} <- apply_ndi_selection(conn, source_params),
         {:ok, source} <- Sources.create(route_id, source_params) do
      conn
      |> put_status(:created)
      |> data(source)
    else
      {:error, code, message, errors} when is_binary(code) ->
        ndi_selection_error(conn, code, message, errors)

      other ->
        other
    end
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t() | {:error, term()}
  def show(conn, %{"id" => id, "route_id" => route_id}) do
    with {:ok, source} <- Sources.get(route_id, id) do
      data(conn, source)
    end
  end

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t() | {:error, term()}
  def update(conn, %{"id" => id, "route_id" => route_id, "source" => source_params}) do
    with {:ok, source_params} <- apply_ndi_selection(conn, source_params),
         {:ok, source} <- Sources.update(route_id, id, source_params) do
      data(conn, source)
    else
      {:error, code, message, errors} when is_binary(code) ->
        ndi_selection_error(conn, code, message, errors)

      other ->
        other
    end
  end

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t() | {:error, term()}
  def delete(conn, %{"id" => id, "route_id" => route_id}) do
    with :ok <- Sources.delete(route_id, id) do
      send_resp(conn, :no_content, "")
    end
  end

  @spec reorder(Plug.Conn.t(), map()) :: Plug.Conn.t() | {:error, term()}
  def reorder(conn, %{"route_id" => route_id, "source_ids" => source_ids}) do
    with {:ok, sources} <- Sources.reorder(route_id, source_ids) do
      data(conn, sources)
    end
  end

  @spec test(Plug.Conn.t(), map()) :: Plug.Conn.t() | {:error, term()}
  def test(conn, %{"id" => id, "route_id" => route_id}) do
    case Sources.test(route_id, id) do
      {:ok, result} ->
        data(conn, result)

      {:error, message} when is_binary(message) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: message})

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec apply_ndi_selection(Plug.Conn.t(), map()) ::
          {:ok, map()} | {:error, String.t(), String.t(), map()}
  def apply_ndi_selection(conn, source_params) when is_map(source_params) do
    SourceNdiSelection.apply_rest_selection(source_params, auth_principal(conn))
  end

  @spec auth_principal(Plug.Conn.t()) :: String.t()
  def auth_principal(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        HydraSrt.Auth.hash_token(token)

      _ ->
        "anonymous"
    end
  end

  @spec ndi_selection_error(Plug.Conn.t(), String.t(), String.t(), map()) :: Plug.Conn.t()
  def ndi_selection_error(conn, code, message, errors)
      when is_binary(code) and is_binary(message) and is_map(errors) do
    status =
      case code do
        "NDI_DISCOVERY_UNAVAILABLE" -> 422
        _ -> 422
      end

    conn
    |> put_status(status)
    |> json(%{error: message, code: code, errors: errors})
  end

  @spec data(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def data(conn, data), do: json(conn, %{data: data})
end

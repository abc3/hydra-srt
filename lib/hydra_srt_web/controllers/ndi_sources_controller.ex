defmodule HydraSrtWeb.NdiSourcesController do
  @moduledoc """
  Lists discovered NDI sources and triggers a coalesced discovery refresh.
  """

  use HydraSrtWeb, :controller

  alias HydraSrt.Ndi.Capabilities
  alias HydraSrtWeb.NdiError

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    principal = auth_principal(conn)
    refresh? = truthy_param?(params["refresh"])
    q = params["q"]

    case Capabilities.list_sources(principal: principal, refresh: refresh?, q: q) do
      {:ok, %{data: data, meta: meta}} ->
        json(conn, %{data: data, meta: meta})

      {:error, code, message} ->
        ndi_error(conn, status_for_code(code), code, message)
    end
  end

  @spec refresh(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def refresh(conn, _params) do
    principal = auth_principal(conn)

    case Capabilities.request_refresh(principal: principal) do
      {:ok, %{generation: generation}} ->
        conn
        |> put_status(202)
        |> json(%{data: %{generation: generation}})

      {:error, code, message} ->
        ndi_error(conn, status_for_code(code), code, message)
    end
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

  @spec truthy_param?(term()) :: boolean()
  def truthy_param?(value) when value in [true, "true", "1", 1], do: true
  def truthy_param?(_), do: false

  @spec status_for_code(String.t()) :: pos_integer()
  def status_for_code("NDI_DISABLED"), do: 424
  def status_for_code("NDI_LEGAL_GATE_DISABLED"), do: 424
  def status_for_code("NDI_CONFIG_INVALID"), do: 422
  def status_for_code(_code), do: 424

  @spec ndi_error(Plug.Conn.t(), pos_integer(), String.t(), String.t()) :: Plug.Conn.t()
  def ndi_error(conn, status, code, message)
      when is_integer(status) and is_binary(code) and is_binary(message) do
    NdiError.render(conn, status, code, message)
  end
end

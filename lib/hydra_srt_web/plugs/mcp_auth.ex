defmodule HydraSrtWeb.Plugs.McpAuth do
  @moduledoc false
  import Plug.Conn

  alias HydraSrt.Db

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        if Db.authenticate_mcp_token(token) do
          conn
        else
          unauthorized(conn)
        end

      _ ->
        unauthorized(conn, "Authorization header missing")
    end
  end

  def unauthorized(conn, message \\ "Unauthorized") do
    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> put_status(401)
    |> Phoenix.Controller.json(%{error: message})
    |> halt()
  end
end

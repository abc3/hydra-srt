defmodule HydraSrtWeb.HealthController do
  use HydraSrtWeb, :controller

  def index(conn, _params) do
    conn
    |> send_resp(200, "")
  end
end

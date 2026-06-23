defmodule HydraSrtWeb.DashboardController do
  use HydraSrtWeb, :controller

  def show(conn, _params) do
    case HydraSrt.Dashboard.snapshot() do
      {:ok, payload} ->
        json(conn, payload)

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to load dashboard: #{inspect(reason)}"})
    end
  end
end

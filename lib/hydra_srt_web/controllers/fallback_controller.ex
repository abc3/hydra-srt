defmodule HydraSrtWeb.FallbackController do
  @moduledoc """
  Translates controller action results into valid `Plug.Conn` responses.

  See `Phoenix.Controller.action_fallback/1` for more details.
  """
  use HydraSrtWeb, :controller

  # This clause handles errors returned by Ecto's insert/update/delete.
  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: HydraSrtWeb.ChangesetJSON)
    |> render(:error, changeset: changeset)
  end

  # This clause is an example of how to handle resources that cannot be found.
  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(html: HydraSrtWeb.ErrorHTML, json: HydraSrtWeb.ErrorJSON)
    |> render(:"404")
  end

  def call(conn, {:error, :invalid_source_order}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "Invalid source order"})
  end

  def call(conn, {:error, :active_source_cannot_be_deleted}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "Active source cannot be deleted"})
  end

  def call(conn, {:error, :source_disabled}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "Source is disabled"})
  end

  def call(conn, {:error, :route_handler_unavailable}) do
    conn
    |> put_status(:conflict)
    |> json(%{error: "Route handler is unavailable for running route"})
  end

  # Catch-all for non-Ecto errors to avoid crashing controller actions that use `with`.
  def call(conn, {:error, _reason}) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{error: "Internal server error"})
  end
end

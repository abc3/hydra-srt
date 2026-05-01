defmodule HydraSrtWeb.SourceController do
  use HydraSrtWeb, :controller

  alias HydraSrt.Db
  alias HydraSrt.SourceProbe

  action_fallback HydraSrtWeb.FallbackController

  def index(conn, %{"route_id" => route_id}) do
    with {:ok, sources} <- Db.get_all_sources(route_id) do
      data(conn, sources)
    end
  end

  def create(conn, %{"source" => source_params, "route_id" => route_id}) do
    with {:ok, source} <- Db.create_source(route_id, source_params) do
      conn
      |> put_status(:created)
      |> data(source)
    end
  end

  def show(conn, %{"id" => id, "route_id" => route_id}) do
    with {:ok, source} <- Db.get_source(route_id, id) do
      data(conn, source)
    end
  end

  def update(conn, %{"id" => id, "route_id" => route_id, "source" => source_params}) do
    with {:ok, source} <- Db.update_source(route_id, id, source_params) do
      data(conn, source)
    end
  end

  def delete(conn, %{"id" => id, "route_id" => route_id}) do
    with :ok <- Db.del_source(route_id, id) do
      send_resp(conn, :no_content, "")
    end
  end

  def reorder(conn, %{"route_id" => route_id, "source_ids" => source_ids}) do
    with {:ok, sources} <- Db.reorder_sources(route_id, source_ids) do
      data(conn, sources)
    end
  end

  def test(conn, %{"id" => id, "route_id" => route_id}) do
    with {:ok, source} <- Db.get_source(route_id, id),
         {:ok, result} <- SourceProbe.probe(source) do
      data(conn, result)
    else
      {:error, reason} when is_binary(reason) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: reason})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  defp data(conn, data), do: json(conn, %{data: data})
end

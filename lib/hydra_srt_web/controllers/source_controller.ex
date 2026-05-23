defmodule HydraSrtWeb.SourceController do
  use HydraSrtWeb, :controller

  alias HydraSrt.Sources

  action_fallback HydraSrtWeb.FallbackController

  def index(conn, %{"route_id" => route_id}) do
    with {:ok, sources} <- Sources.list(route_id) do
      data(conn, sources)
    end
  end

  def create(conn, %{"source" => source_params, "route_id" => route_id}) do
    with {:ok, source} <- Sources.create(route_id, source_params) do
      conn
      |> put_status(:created)
      |> data(source)
    end
  end

  def show(conn, %{"id" => id, "route_id" => route_id}) do
    with {:ok, source} <- Sources.get(route_id, id) do
      data(conn, source)
    end
  end

  def update(conn, %{"id" => id, "route_id" => route_id, "source" => source_params}) do
    with {:ok, source} <- Sources.update(route_id, id, source_params) do
      data(conn, source)
    end
  end

  def delete(conn, %{"id" => id, "route_id" => route_id}) do
    with :ok <- Sources.delete(route_id, id) do
      send_resp(conn, :no_content, "")
    end
  end

  def reorder(conn, %{"route_id" => route_id, "source_ids" => source_ids}) do
    with {:ok, sources} <- Sources.reorder(route_id, source_ids) do
      data(conn, sources)
    end
  end

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

  defp data(conn, data), do: json(conn, %{data: data})
end

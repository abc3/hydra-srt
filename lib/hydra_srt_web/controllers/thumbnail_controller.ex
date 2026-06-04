defmodule HydraSrtWeb.ThumbnailController do
  use HydraSrtWeb, :controller

  action_fallback HydraSrtWeb.FallbackController

  def show(conn, %{"route_id" => route_id, "id" => source_id}) do
    with {:ok, thumbnail} <- HydraSrt.Thumbnails.get(route_id, source_id) do
      conn
      |> put_resp_content_type("image/jpeg")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("etag", ~s("#{thumbnail.version}"))
      |> send_resp(:ok, thumbnail.bytes)
    end
  end
end

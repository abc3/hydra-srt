defmodule HydraSrtWeb.PageController do
  use HydraSrtWeb, :controller

  def index(conn, %{"path" => ["index.html" | _rest]}) do
    conn
    |> redirect(to: "/")
    |> halt()
  end

  def index(conn, %{"path" => _path}) do
    serve_index_html(conn)
  end

  def index(conn, _params) do
    serve_index_html(conn)
  end

  defp serve_index_html(conn) do
    conn
    |> put_resp_header("content-type", "text/html; charset=utf-8")
    |> Plug.Conn.send_file(200, Application.app_dir(:hydra_srt, "priv/static/index.html"))
  end
end

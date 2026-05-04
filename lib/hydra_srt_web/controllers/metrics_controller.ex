defmodule HydraSrtWeb.MetricsController do
  use HydraSrtWeb, :controller

  def index(conn, _params) do
    case Application.get_env(:hydra_srt, :metrics_secret) do
      nil ->
        send_metrics(conn)

      secret ->
        case get_req_header(conn, "authorization") do
          ["Bearer " <> ^secret] ->
            send_metrics(conn)

          _ ->
            conn
            |> put_status(403)
            |> json(%{error: "Unauthorized"})
        end
    end
  end

  defp send_metrics(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, HydraSrt.PromEx.get_metrics())
  end
end

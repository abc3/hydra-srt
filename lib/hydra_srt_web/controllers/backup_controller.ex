defmodule HydraSrtWeb.BackupController do
  use HydraSrtWeb, :controller

  alias HydraSrt.Db

  def export(conn, _params) do
    with {:ok, routes} <- Db.get_all_routes(true) do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header(
        "content-disposition",
        "inline; filename=\"hydra_srt_routes_backup.json\""
      )
      |> json(%{data: routes})
    else
      error ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to export routes: #{inspect(error)}"})
    end
  end

  def create_download_link(conn, _params) do
    session_id = UUID.uuid4()

    Cachex.put(HydraSrt.Cache, "backup_session:#{session_id}", true, ttl: :timer.minutes(5))

    conn
    |> put_status(:ok)
    |> json(%{download_link: "/backup/#{session_id}/download"})
  end

  def create_backup_download_link(conn, _params) do
    session_id = UUID.uuid4()

    Cachex.put(HydraSrt.Cache, "backup_binary_session:#{session_id}", true,
      ttl: :timer.minutes(5)
    )

    conn
    |> put_status(:ok)
    |> json(%{download_link: "/backup/#{session_id}/download_backup"})
  end

  def download(conn, %{"session_id" => session_id}) do
    case Cachex.get(HydraSrt.Cache, "backup_session:#{session_id}") do
      {:ok, true} ->
        with {:ok, routes} <- Db.get_all_routes(true) do
          Cachex.del(HydraSrt.Cache, "backup_session:#{session_id}")

          json_data = Jason.encode!(routes, pretty: true)

          now = DateTime.utc_now()
          formatted_time = Calendar.strftime(now, "%m-%d-%y-%H:%M:%S")
          filename = "hydra-routes-#{formatted_time}.json"

          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header(
            "content-disposition",
            "attachment; filename=\"#{filename}\""
          )
          |> send_resp(200, json_data)
        else
          error ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Failed to download routes backup: #{inspect(error)}"})
        end

      _ ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Invalid or expired download link"})
    end
  end

  def download_backup(conn, %{"session_id" => session_id}) do
    case Cachex.get(HydraSrt.Cache, "backup_binary_session:#{session_id}") do
      {:ok, true} ->
        with {:ok, binary_data} <- Db.backup() do
          Cachex.del(HydraSrt.Cache, "backup_binary_session:#{session_id}")

          now = DateTime.utc_now()
          formatted_time = Calendar.strftime(now, "%m-%d-%y-%H:%M:%S")
          filename = "hydra-srt-#{formatted_time}.backup"

          conn
          |> put_resp_content_type("application/octet-stream")
          |> put_resp_header(
            "content-disposition",
            "attachment; filename=\"#{filename}\""
          )
          |> send_resp(200, binary_data)
        else
          error ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Failed to download backup: #{inspect(error)}"})
        end

      _ ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Invalid or expired download link"})
    end
  end

  def restore(conn, _params) do
    try do
      {:ok, binary_data, _conn} = Plug.Conn.read_body(conn)
      IO.puts("Received binary data of size: #{byte_size(binary_data)} bytes")

      case Db.restore_backup(binary_data) do
        :ok ->
          conn
          |> put_status(:ok)
          |> json(%{message: "Backup restored successfully"})

        {:error, reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{error: "Failed to restore backup: #{inspect(reason)}"})
      end
    rescue
      e ->
        IO.puts("Error processing backup: #{inspect(e)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to process backup: #{inspect(e)}"})
    end
  end
end

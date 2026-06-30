defmodule HydraSrtWeb.BackupController do
  use HydraSrtWeb, :controller

  alias HydraSrt.Db
  alias HydraSrt.RouteBackup

  @spec export_routes(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def export_routes(conn, _params) do
    with {:ok, backup} <- RouteBackup.export(),
         {:ok, json} <- Jason.encode(backup, pretty: true) do
      timestamp = DateTime.utc_now() |> Calendar.strftime("%d%m%y%H%M")
      filename = "hydra-srt-routes-#{timestamp}.json"

      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header(
        "content-disposition",
        "attachment; filename=\"#{filename}\""
      )
      |> send_resp(200, json)
    else
      error ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to export route backup: #{inspect(error)}"})
    end
  end

  @spec import_routes(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def import_routes(conn, params) do
    case RouteBackup.import(params) do
      {:ok, count} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "Route backup imported successfully", routes_created: count})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to import route backup: #{inspect(reason)}"})
    end
  end

  @spec download_backup(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def download_backup(conn, _params) do
    with {:ok, binary_data} <- Db.backup() do
      filename = "hydra-srt-#{timestamp()}.db"

      conn
      |> put_resp_content_type("application/octet-stream")
      |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
      |> send_resp(200, binary_data)
    else
      error ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to download backup: #{inspect(error)}"})
    end
  end

  @spec restore(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def restore(conn, _params) do
    with {:ok, binary_data, conn} <- read_request_body(conn),
         :ok <- Db.restore_backup(binary_data) do
      conn
      |> put_status(:ok)
      |> json(%{message: "Backup restored successfully"})
    else
      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to restore backup: #{inspect(reason)}"})
    end
  end

  @spec read_request_body(Plug.Conn.t(), iodata()) ::
          {:ok, binary(), Plug.Conn.t()} | {:error, term()}
  def read_request_body(conn, acc \\ []) do
    case Plug.Conn.read_body(conn, length: 100_000_000, read_length: 1_000_000) do
      {:ok, chunk, conn} -> {:ok, IO.iodata_to_binary(Enum.reverse([chunk | acc])), conn}
      {:more, chunk, conn} -> read_request_body(conn, [chunk | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  @spec timestamp() :: binary()
  def timestamp do
    DateTime.utc_now() |> Calendar.strftime("%Y-%m-%dT%H-%M-%SZ")
  end
end

defmodule HydraSrtWeb.SystemController do
  use HydraSrtWeb, :controller

  alias HydraSrt.ProcessMonitor
  alias HydraSrt.Helpers

  def list_pipelines(conn, _params) do
    pipelines = ProcessMonitor.list_pipeline_processes()
    json(conn, pipelines)
  end

  def list_pipelines_detailed(conn, _params) do
    pipelines = ProcessMonitor.list_pipeline_processes_detailed()
    json(conn, pipelines)
  end

  def kill_pipeline(conn, %{"pid" => pid_str}) do
    with {pid, _} <- Integer.parse(pid_str),
         {_, 0} <- Helpers.sys_kill(pid_str) do
      json(conn, %{success: true, message: "Process #{pid} killed successfully"})
    else
      :error ->
        conn
        |> put_status(400)
        |> json(%{error: "Invalid PID format"})

      {error, _} ->
        conn
        |> put_status(500)
        |> json(%{error: "Failed to kill process: #{inspect(error)}"})
    end
  end
end

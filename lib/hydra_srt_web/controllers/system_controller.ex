defmodule HydraSrtWeb.SystemController do
  use HydraSrtWeb, :controller

  alias HydraSrt.ProcessMonitor
  alias HydraSrt.Helpers
  alias HydraSrt.SignalGenerator

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

  def signal_generation_status(conn, _params) do
    transport = Map.get(conn.params, "transport", "srt")

    case SignalGenerator.status(transport) do
      {:error, :invalid_transport} ->
        conn
        |> put_status(400)
        |> json(%{error: "Invalid transport. Use srt, udp, or rtp"})

      status ->
        json(conn, status)
    end
  end

  def signal_generation_configure(conn, %{"host" => host, "port" => port} = params) do
    transport = Map.get(params, "transport", "srt")

    with {:ok, port_i} <- parse_port(port),
         {:ok, status} <- SignalGenerator.configure(transport, host, port_i) do
      json(conn, status)
    else
      {:error, :invalid_transport} ->
        conn
        |> put_status(400)
        |> json(%{error: "Invalid transport. Use srt, udp, or rtp"})

      {:error, :invalid_port} ->
        conn
        |> put_status(400)
        |> json(%{error: "Invalid port"})

      {:error, :invalid_host} ->
        conn
        |> put_status(400)
        |> json(%{error: "Invalid host"})

      {:error, :running} ->
        conn
        |> put_status(409)
        |> json(%{error: "Stop signal generation before changing host/port/transport"})
    end
  end

  def signal_generation_start(conn, params) do
    transport = Map.get(params, "transport", "srt")

    case SignalGenerator.start_generation(transport) do
      {:ok, status} ->
        json(conn, status)

      {:error, :invalid_transport} ->
        conn
        |> put_status(400)
        |> json(%{error: "Invalid transport. Use srt, udp, or rtp"})

      {:error, :already_running} ->
        conn
        |> put_status(409)
        |> json(%{error: "Signal generation already running"})

      {:error, :ffmpeg_not_found} ->
        conn
        |> put_status(500)
        |> json(%{error: "ffmpeg is not installed or not available in PATH"})
    end
  end

  def signal_generation_stop(conn, params) do
    transport = Map.get(params, "transport", "srt")
    {:ok, status} = SignalGenerator.stop_generation(transport)
    json(conn, status)
  end

  defp parse_port(port) when is_integer(port), do: {:ok, port}

  defp parse_port(port) when is_binary(port) do
    case Integer.parse(port) do
      {value, ""} -> {:ok, value}
      _ -> {:error, :invalid_port}
    end
  end

  defp parse_port(_port), do: {:error, :invalid_port}
end

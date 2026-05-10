defmodule HydraSrt.SignalGenerator do
  @moduledoc false
  use GenServer

  @default_host "127.0.0.1"
  @default_port 4200
  @stale_signature "HYDRA_SIGNAL_GENERATOR"

  @ffmpeg_base_args [
    "-hide_banner",
    "-loglevel",
    "error",
    "-re",
    "-f",
    "lavfi",
    "-i",
    "testsrc=size=1280x720:rate=30",
    "-f",
    "lavfi",
    "-i",
    "sine=frequency=440:sample_rate=48000",
    "-c:v",
    "libx264",
    "-preset",
    "veryfast",
    "-tune",
    "zerolatency",
    "-b:v",
    "2000k",
    "-c:a",
    "aac",
    "-b:a",
    "128k",
    "-metadata",
    "title=HYDRA_SIGNAL_GENERATOR",
    "-f",
    "mpegts"
  ]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  def configure(host, port) when is_binary(host) and is_integer(port) do
    GenServer.call(__MODULE__, {:configure, host, port})
  end

  def start_generation do
    GenServer.call(__MODULE__, :start_generation)
  end

  def stop_generation do
    GenServer.call(__MODULE__, :stop_generation)
  end

  @impl true
  def init(_state) do
    Process.flag(:trap_exit, true)
    cleanup_stale_ffmpeg()

    {:ok,
     %{
       host: @default_host,
       port: @default_port,
       ffmpeg_port: nil,
       ffmpeg_pid: nil,
       ffmpeg_path: System.find_executable("ffmpeg")
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_map(state), state}
  end

  def handle_call({:configure, host, port}, _from, state) do
    host = String.trim(host)

    cond do
      host == "" ->
        {:reply, {:error, :invalid_host}, state}

      port < 1 or port > 65_535 ->
        {:reply, {:error, :invalid_port}, state}

      is_port(state.ffmpeg_port) ->
        {:reply, {:error, :running}, state}

      true ->
        new_state = %{state | host: host, port: port}
        {:reply, {:ok, status_map(new_state)}, new_state}
    end
  end

  def handle_call(:start_generation, _from, state) do
    cond do
      is_port(state.ffmpeg_port) ->
        {:reply, {:error, :already_running}, state}

      is_nil(state.ffmpeg_path) ->
        {:reply, {:error, :ffmpeg_not_found}, state}

      true ->
        output = "srt://#{state.host}:#{state.port}?mode=listener"

        ffmpeg_port =
          Port.open({:spawn_executable, state.ffmpeg_path}, [
            :binary,
            :use_stdio,
            :exit_status,
            :stderr_to_stdout,
            args: @ffmpeg_base_args ++ [output]
          ])

        ffmpeg_pid =
          case Port.info(ffmpeg_port, :os_pid) do
            {:os_pid, pid} when is_integer(pid) and pid > 0 -> pid
            _ -> nil
          end

        new_state = %{state | ffmpeg_port: ffmpeg_port, ffmpeg_pid: ffmpeg_pid}
        {:reply, {:ok, status_map(new_state)}, new_state}
    end
  end

  def handle_call(:stop_generation, _from, state) do
    if is_port(state.ffmpeg_port) do
      safe_close_port(state.ffmpeg_port)
      safe_kill_pid(state.ffmpeg_pid)
      new_state = %{state | ffmpeg_port: nil, ffmpeg_pid: nil}
      {:reply, {:ok, status_map(new_state)}, new_state}
    else
      {:reply, {:ok, status_map(state)}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, _data}}, %{ffmpeg_port: port} = state) do
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, _status}}, %{ffmpeg_port: port} = state) do
    {:noreply, %{state | ffmpeg_port: nil, ffmpeg_pid: nil}}
  end

  def handle_info({:EXIT, port, _reason}, %{ffmpeg_port: port} = state) do
    {:noreply, %{state | ffmpeg_port: nil, ffmpeg_pid: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    safe_close_port(state.ffmpeg_port)
    safe_kill_pid(state.ffmpeg_pid)
    :ok
  end

  defp status_map(state) do
    %{
      "running" => is_port(state.ffmpeg_port),
      "host" => state.host,
      "port" => state.port
    }
  end

  defp safe_close_port(port) when is_port(port) do
    try do
      Port.close(port)
    catch
      :error, _ -> :ok
    end
  end

  defp safe_close_port(_), do: :ok

  defp safe_kill_pid(pid) when is_integer(pid) and pid > 0 do
    pid_s = Integer.to_string(pid)
    _ = System.cmd("kill", ["-TERM", pid_s], stderr_to_stdout: true)
    Process.sleep(200)

    case System.cmd("kill", ["-0", pid_s], stderr_to_stdout: true) do
      {_out, 0} -> _ = System.cmd("kill", ["-KILL", pid_s], stderr_to_stdout: true)
      _ -> :ok
    end
  end

  defp safe_kill_pid(_), do: :ok

  defp cleanup_stale_ffmpeg do
    case System.cmd("pgrep", ["-f", @stale_signature], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&(&1 != ""))
        |> Enum.each(fn pid ->
          _ = System.cmd("kill", ["-TERM", pid], stderr_to_stdout: true)
        end)

      {_output, _code} ->
        :ok
    end
  end
end

defmodule HydraSrt.DemoFfmpegServer do
  @moduledoc false
  use GenServer

  require Logger

  @restart_delay_ms 3_000

  @ffmpeg_args [
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
    "-f",
    "mpegts",
    "srt://127.0.0.1:4200?mode=listener"
  ]

  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, start_ffmpeg(state)}
  end

  @impl true
  def handle_info({_port, {:data, _data}}, state) do
    {:noreply, state}
  end

  def handle_info({_port, {:exit_status, status}}, state) do
    Logger.warning(
      "Demo ffmpeg exited with status=#{status}; restarting in #{@restart_delay_ms}ms"
    )

    Process.send_after(self(), :restart_ffmpeg, @restart_delay_ms)
    {:noreply, %{state | port: nil}}
  end

  def handle_info(:restart_ffmpeg, state) do
    {:noreply, start_ffmpeg(state)}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.warning(
      "Demo ffmpeg port exited reason=#{inspect(reason)}; restarting in #{@restart_delay_ms}ms"
    )

    Process.send_after(self(), :restart_ffmpeg, @restart_delay_ms)
    {:noreply, %{state | port: nil}}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    Port.close(port)
    :ok
  catch
    :error, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp start_ffmpeg(state) do
    ffmpeg_path = System.find_executable("ffmpeg") || "ffmpeg"

    port =
      Port.open({:spawn_executable, ffmpeg_path}, [
        :binary,
        :use_stdio,
        :exit_status,
        :stderr_to_stdout,
        args: @ffmpeg_args
      ])

    Logger.info("Demo ffmpeg stream started")
    Map.put(state, :port, port)
  end
end

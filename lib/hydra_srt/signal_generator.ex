defmodule HydraSrt.SignalGenerator do
  @moduledoc false
  use GenServer

  @default_host "127.0.0.1"
  @default_srt_port 4200
  @default_udp_port 4201
  @default_rtp_port 4202
  @default_rtmp_port 1935
  @default_rtmp_path "/live/test"
  @stale_signature "HYDRA_SIGNAL_GENERATOR"
  @supported_transports ["srt", "udp", "rtp", "rtmp"]
  @restart_delay_ms 2_000

  @ffmpeg_common_args [
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
    "-pix_fmt",
    "yuv420p",
    "-profile:v",
    "baseline",
    "-g",
    "60",
    "-b:v",
    "2000k",
    "-c:a",
    "aac",
    "-b:a",
    "128k",
    "-metadata",
    "title=HYDRA_SIGNAL_GENERATOR"
  ]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def status(transport \\ "srt") do
    GenServer.call(__MODULE__, {:status, transport})
  end

  def configure(transport, host, port, path \\ nil)
      when is_binary(transport) and is_binary(host) and is_integer(port) do
    GenServer.call(__MODULE__, {:configure, transport, host, port, path})
  end

  def start_generation(transport \\ "srt") do
    GenServer.call(__MODULE__, {:start_generation, transport})
  end

  def stop_generation(transport \\ "srt") do
    GenServer.call(__MODULE__, {:stop_generation, transport})
  end

  @doc false
  def restart_delay_ms, do: @restart_delay_ms

  @impl true
  def init(_state) do
    Process.flag(:trap_exit, true)
    cleanup_stale_ffmpeg()

    {:ok,
     %{
       configs: %{
         "srt" => %{host: @default_host, port: @default_srt_port},
         "udp" => %{host: @default_host, port: @default_udp_port},
         "rtp" => %{host: @default_host, port: @default_rtp_port},
         "rtmp" => %{host: @default_host, port: @default_rtmp_port, path: @default_rtmp_path}
       },
       running_transport: nil,
       ffmpeg_port: nil,
       ffmpeg_pid: nil,
       ffmpeg_path: System.find_executable("ffmpeg"),
       auto_restart: false,
       restart_timer_ref: nil
     }}
  end

  @impl true
  def handle_call({:status, transport}, _from, state) do
    with {:ok, transport} <- normalize_transport(transport) do
      {:reply, status_map(state, transport), state}
    else
      {:error, :invalid_transport} ->
        {:reply, {:error, :invalid_transport}, state}
    end
  end

  def handle_call({:configure, transport, host, port, path}, _from, state) do
    host = String.trim(host)

    with {:ok, transport} <- normalize_transport(transport),
         {:ok, path} <- resolve_rtmp_path(transport, path, state) do
      cond do
        host == "" ->
          {:reply, {:error, :invalid_host}, state}

        port < 1 or port > 65_535 ->
          {:reply, {:error, :invalid_port}, state}

        transport == "rtmp" and is_nil(path) ->
          {:reply, {:error, :invalid_path}, state}

        is_port(state.ffmpeg_port) ->
          {:reply, {:error, :running}, state}

        true ->
          cfg = %{host: host, port: port} |> maybe_put_path(transport, path)
          new_configs = put_in(state.configs, [transport], cfg)
          new_state = %{state | configs: new_configs}
          {:reply, {:ok, status_map(new_state, transport)}, new_state}
      end
    else
      {:error, :invalid_transport} ->
        {:reply, {:error, :invalid_transport}, state}
    end
  end

  def handle_call({:start_generation, transport}, _from, state) do
    with {:ok, transport} <- normalize_transport(transport) do
      cond do
        is_port(state.ffmpeg_port) ->
          {:reply, {:error, :already_running}, state}

        is_nil(state.ffmpeg_path) ->
          {:reply, {:error, :ffmpeg_not_found}, state}

        true ->
          new_state =
            state
            |> cancel_pending_restart()
            |> launch_ffmpeg(transport)
            |> Map.put(:auto_restart, true)

          {:reply, {:ok, status_map(new_state, transport)}, new_state}
      end
    else
      {:error, :invalid_transport} ->
        {:reply, {:error, :invalid_transport}, state}
    end
  end

  def handle_call({:stop_generation, transport}, _from, state) do
    transport = normalize_transport_or_default(transport)
    state = disable_auto_restart(state)

    if is_port(state.ffmpeg_port) do
      safe_close_port(state.ffmpeg_port)
      safe_kill_pid(state.ffmpeg_pid)
      new_state = %{state | ffmpeg_port: nil, ffmpeg_pid: nil, running_transport: nil}
      {:reply, {:ok, status_map(new_state, transport)}, new_state}
    else
      {:reply, {:ok, status_map(state, transport)}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, _data}}, %{ffmpeg_port: port} = state) do
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, _status}}, %{ffmpeg_port: port} = state) do
    {:noreply, schedule_restart_after_exit(state)}
  end

  def handle_info({:EXIT, port, _reason}, %{ffmpeg_port: port} = state) do
    {:noreply, schedule_restart_after_exit(state)}
  end

  def handle_info({:restart_generation, transport}, state) do
    state = %{state | restart_timer_ref: nil}

    cond do
      not state.auto_restart ->
        {:noreply, state}

      is_port(state.ffmpeg_port) ->
        {:noreply, state}

      is_nil(state.ffmpeg_path) ->
        {:noreply, %{state | auto_restart: false}}

      true ->
        {:noreply, launch_ffmpeg(state, transport)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = cancel_pending_restart(state)
    safe_close_port(state.ffmpeg_port)
    safe_kill_pid(state.ffmpeg_pid)
    :ok
  end

  defp launch_ffmpeg(state, transport) do
    cfg = Map.fetch!(state.configs, transport)
    output = output_url(transport, cfg.host, cfg.port, Map.get(cfg, :path))

    ffmpeg_port =
      Port.open({:spawn_executable, state.ffmpeg_path}, [
        :binary,
        :use_stdio,
        :exit_status,
        :stderr_to_stdout,
        args: @ffmpeg_common_args ++ format_args(transport) ++ [output]
      ])

    ffmpeg_pid =
      case Port.info(ffmpeg_port, :os_pid) do
        {:os_pid, pid} when is_integer(pid) and pid > 0 -> pid
        _ -> nil
      end

    %{
      state
      | ffmpeg_port: ffmpeg_port,
        ffmpeg_pid: ffmpeg_pid,
        running_transport: transport
    }
  end

  defp schedule_restart_after_exit(state) do
    transport = state.running_transport

    state =
      state
      |> Map.merge(%{ffmpeg_port: nil, ffmpeg_pid: nil, running_transport: nil})
      |> cancel_pending_restart()

    if state.auto_restart and is_binary(transport) do
      ref = Process.send_after(self(), {:restart_generation, transport}, @restart_delay_ms)
      %{state | restart_timer_ref: ref}
    else
      state
    end
  end

  defp disable_auto_restart(state) do
    state
    |> cancel_pending_restart()
    |> Map.put(:auto_restart, false)
  end

  defp cancel_pending_restart(%{restart_timer_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | restart_timer_ref: nil}
  end

  defp cancel_pending_restart(state), do: state

  defp status_map(state, transport) do
    cfg = Map.fetch!(state.configs, transport)

    %{
      "transport" => transport,
      "running" => is_port(state.ffmpeg_port) and state.running_transport == transport,
      "running_transport" => state.running_transport,
      "host" => cfg.host,
      "port" => cfg.port,
      "transports" => %{
        "srt" => %{
          "host" => state.configs["srt"].host,
          "port" => state.configs["srt"].port
        },
        "udp" => %{
          "host" => state.configs["udp"].host,
          "port" => state.configs["udp"].port
        },
        "rtp" => %{
          "host" => state.configs["rtp"].host,
          "port" => state.configs["rtp"].port
        },
        "rtmp" => %{
          "host" => state.configs["rtmp"].host,
          "port" => state.configs["rtmp"].port,
          "path" => state.configs["rtmp"].path
        }
      }
    }
    |> Map.put("path", Map.get(cfg, :path))
  end

  defp normalize_transport(transport) when is_binary(transport) do
    normalized = transport |> String.trim() |> String.downcase()

    if normalized in @supported_transports,
      do: {:ok, normalized},
      else: {:error, :invalid_transport}
  end

  defp normalize_transport(_), do: {:error, :invalid_transport}

  defp normalize_transport_or_default(transport) do
    case normalize_transport(transport) do
      {:ok, normalized} -> normalized
      _ -> "srt"
    end
  end

  defp resolve_rtmp_path("rtmp", nil, state) do
    case get_in(state.configs, ["rtmp", :path]) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, :invalid_path}
    end
  end

  defp resolve_rtmp_path("rtmp", path, _state) when is_binary(path) do
    case HydraSrt.Api.Endpoint.normalize_rtmp_path(path) do
      normalized when is_binary(normalized) and normalized != "" -> {:ok, normalized}
      _ -> {:error, :invalid_path}
    end
  end

  defp resolve_rtmp_path(_transport, _path, _state), do: {:ok, nil}

  defp maybe_put_path(cfg, "rtmp", path), do: Map.put(cfg, :path, path)
  defp maybe_put_path(cfg, _transport, _path), do: cfg

  defp format_args("srt"), do: ["-f", "mpegts"]
  defp format_args("udp"), do: ["-f", "mpegts"]
  defp format_args("rtp"), do: ["-f", "rtp_mpegts"]
  defp format_args("rtmp"), do: ["-f", "flv"]

  defp output_url("srt", host, port, _path), do: "srt://#{host}:#{port}?mode=listener"
  defp output_url("udp", host, port, _path), do: "udp://#{host}:#{port}?pkt_size=1316"
  defp output_url("rtp", host, port, _path), do: "rtp://#{host}:#{port}"
  defp output_url("rtmp", host, port, path), do: "rtmp://#{host}:#{port}#{path}"

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

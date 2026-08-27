defmodule HydraSrt.TestSupport.HlsGenerator do
  @moduledoc """
  Generates a local HLS fixture with ffmpeg.

  The returned process owns ffmpeg and the fixture directory. Link it to the
  test process so an abnormal test exit also tears down the fixture.
  """

  @default_width 1280
  @default_height 720
  @default_fps 30
  @default_segment_duration 1
  @default_live_list_size 8
  @startup_timeout_ms :timer.seconds(20)

  @type handle :: %{
          pid: pid(),
          ref: reference(),
          port: port(),
          os_pid: pos_integer() | nil,
          directory: String.t(),
          playlist: String.t(),
          url_path: String.t(),
          mode: :live | :vod
        }

  @spec start(keyword()) :: {:ok, handle()} | {:error, term()}
  def start(opts \\ []) when is_list(opts) do
    case System.find_executable("ffmpeg") do
      nil ->
        {:error, :ffmpeg_not_found}

      ffmpeg ->
        parent = self()
        ref = make_ref()
        pid = spawn_link(__MODULE__, :run, [parent, ref, ffmpeg, opts])

        receive do
          {:hls_generator_ready, ^ref, result} -> result
        after
          @startup_timeout_ms ->
            send(pid, {:stop, self(), ref})
            {:error, :startup_timeout}
        end
    end
  end

  @spec run(pid(), reference(), String.t(), keyword()) :: no_return()
  def run(owner, ref, ffmpeg, opts) do
    Process.flag(:trap_exit, true)

    mode = Keyword.get(opts, :mode, :live)
    directory = temp_directory!()
    File.mkdir_p!(Path.join(directory, "file"))
    playlist = Path.join(directory, "playlist.m3u8")
    args = ffmpeg_args(directory, playlist, mode, opts)

    port =
      Port.open({:spawn_executable, String.to_charlist(ffmpeg)}, [
        :binary,
        :use_stdio,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: args
      ])

    os_pid = port_os_pid(port)

    case await_playlist(port, playlist, mode, System.monotonic_time(:millisecond)) do
      :ok ->
        handle = %{
          pid: self(),
          ref: ref,
          port: port,
          os_pid: os_pid,
          directory: directory,
          playlist: playlist,
          url_path: "/playlist.m3u8",
          mode: mode
        }

        send(owner, {:hls_generator_ready, ref, {:ok, handle}})
        loop(owner, handle)

      {:error, reason} ->
        stop_ffmpeg(port, os_pid)
        File.rm_rf!(directory)
        send(owner, {:hls_generator_ready, ref, {:error, reason}})
    end
  end

  @spec stop(handle()) :: :ok
  def stop(%{pid: pid, ref: ref}) when is_pid(pid) do
    if Process.alive?(pid) do
      send(pid, {:stop, self(), ref})

      receive do
        {:hls_generator_stopped, ^ref} -> :ok
      after
        @startup_timeout_ms ->
          Process.exit(pid, :kill)
          :ok
      end
    else
      :ok
    end
  end

  @spec playlist_path(handle()) :: String.t()
  def playlist_path(%{playlist: playlist}), do: playlist

  @spec directory(handle()) :: String.t()
  def directory(%{directory: directory}), do: directory

  @spec url_path(handle()) :: String.t()
  def url_path(%{url_path: url_path}), do: url_path

  @spec read_playlist(handle()) :: {:ok, String.t()} | {:error, term()}
  def read_playlist(%{playlist: playlist}), do: File.read(playlist)

  @spec ffmpeg_args(String.t(), String.t(), :live | :vod, keyword()) :: [String.t()]
  def ffmpeg_args(directory, playlist, mode, opts)
      when is_binary(directory) and is_binary(playlist) and mode in [:live, :vod] do
    width = positive_integer_option(opts, :width, @default_width)
    height = positive_integer_option(opts, :height, @default_height)
    fps = positive_integer_option(opts, :fps, @default_fps)

    segment_duration =
      positive_integer_option(opts, :segment_duration_sec, @default_segment_duration)

    list_size = positive_integer_option(opts, :list_size, @default_live_list_size)
    realtime = Keyword.get(opts, :realtime, mode == :live)
    segment_pattern = Path.join([directory, "file", "seg_%06d.ts"])

    common =
      [
        "-hide_banner",
        "-loglevel",
        "error"
      ] ++
        if(realtime, do: ["-re"], else: []) ++
        [
          "-f",
          "lavfi",
          "-i",
          "testsrc2=size=#{width}x#{height}:rate=#{fps}",
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
          "-g",
          Integer.to_string(fps * segment_duration),
          "-keyint_min",
          Integer.to_string(fps * segment_duration),
          "-sc_threshold",
          "0",
          "-c:a",
          "aac",
          "-b:a",
          "128k",
          "-ar",
          "48000",
          "-ac",
          "2"
        ]

    mode_args =
      case mode do
        :live ->
          [
            "-f",
            "hls",
            "-hls_time",
            Integer.to_string(segment_duration),
            "-hls_list_size",
            Integer.to_string(list_size),
            "-hls_flags",
            "delete_segments+independent_segments",
            "-hls_segment_filename",
            segment_pattern,
            playlist
          ]

        :vod ->
          duration = positive_integer_option(opts, :duration_sec, 6)

          [
            "-t",
            Integer.to_string(duration),
            "-f",
            "hls",
            "-hls_time",
            Integer.to_string(segment_duration),
            "-hls_playlist_type",
            "vod",
            "-hls_flags",
            "independent_segments",
            "-hls_segment_filename",
            segment_pattern,
            playlist
          ]
      end

    common ++ mode_args
  end

  @spec await_playlist(port(), String.t(), :live | :vod, integer()) :: :ok | {:error, atom()}
  def await_playlist(port, playlist, mode, started_at_ms)
      when is_port(port) and is_binary(playlist) and mode in [:live, :vod] do
    cond do
      File.exists?(playlist) and playlist_ready?(playlist, mode) ->
        :ok

      System.monotonic_time(:millisecond) - started_at_ms > @startup_timeout_ms ->
        {:error, :playlist_timeout}

      true ->
        receive do
          {^port, {:data, _data}} ->
            await_playlist(port, playlist, mode, started_at_ms)

          {^port, {:exit_status, _status}} ->
            if File.exists?(playlist) and playlist_ready?(playlist, mode) do
              :ok
            else
              {:error, :ffmpeg_exited}
            end
        after
          100 -> await_playlist(port, playlist, mode, started_at_ms)
        end
    end
  end

  @spec playlist_ready?(String.t(), :live | :vod) :: boolean()
  def playlist_ready?(playlist, :live) do
    case File.read(playlist) do
      {:ok, body} ->
        String.contains?(body, "#EXTINF:") and not String.contains?(body, "#EXT-X-ENDLIST")

      _ ->
        false
    end
  end

  @spec playlist_ready?(String.t(), :live | :vod) :: boolean()
  def playlist_ready?(playlist, :vod) do
    case File.read(playlist) do
      {:ok, body} ->
        String.contains?(body, "#EXTINF:") and String.contains?(body, "#EXT-X-ENDLIST")

      _ ->
        false
    end
  end

  @spec loop(pid(), handle()) :: no_return()
  def loop(owner, %{port: port, os_pid: os_pid, directory: directory, ref: ref} = handle) do
    receive do
      {:stop, ^owner, ^ref} ->
        stop_ffmpeg(port, os_pid)
        File.rm_rf!(directory)
        send(owner, {:hls_generator_stopped, ref})

      {^port, {:exit_status, _status}} ->
        File.rm_rf!(directory)
        send(owner, {:hls_generator_stopped, ref})

      {:EXIT, ^port, _reason} ->
        File.rm_rf!(directory)
        send(owner, {:hls_generator_stopped, ref})

      {:EXIT, ^owner, _reason} ->
        stop_ffmpeg(port, os_pid)
        File.rm_rf!(directory)

      {^port, {:data, _data}} ->
        loop(owner, handle)
    end
  end

  @spec temp_directory!() :: String.t()
  def temp_directory! do
    directory = Path.join(System.tmp_dir!(), "hydra_hls_#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    directory
  end

  @spec positive_integer_option(keyword(), atom(), pos_integer()) :: pos_integer()
  def positive_integer_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  @spec port_os_pid(port()) :: pos_integer() | nil
  def port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 0 -> pid
      _ -> nil
    end
  end

  @spec stop_ffmpeg(port(), pos_integer() | nil) :: :ok
  def stop_ffmpeg(port, os_pid) do
    if is_integer(os_pid) and process_alive?(os_pid) do
      _ = System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
      wait_for_exit(os_pid, System.monotonic_time(:millisecond) + 1_000)
    end

    if is_port(port) do
      try do
        Port.close(port)
      catch
        :error, _ -> :ok
      end
    end

    if is_integer(os_pid) and process_alive?(os_pid) do
      _ = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    :ok
  end

  @spec wait_for_exit(pos_integer(), integer()) :: :ok
  def wait_for_exit(os_pid, deadline_ms) do
    if process_alive?(os_pid) and System.monotonic_time(:millisecond) < deadline_ms do
      receive do
      after
        25 -> wait_for_exit(os_pid, deadline_ms)
      end
    else
      :ok
    end
  end

  @spec process_alive?(pos_integer()) :: boolean()
  def process_alive?(os_pid) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  end
end

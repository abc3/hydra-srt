defmodule HydraSrt.TestSupport.E2EHelpers do
  @moduledoc false

  require Logger

  @default_host "127.0.0.1"
  @default_port 4002

  def ensure_e2e_prereqs! do
    kill_all_pipelines!()
    ensure_executables!()
    ensure_native_built!()
    ensure_api_auth_config!()
    ensure_cachex_started!()
    ensure_repo_config_for_e2e!()
    ensure_app_started!()
    ensure_repo_migrated_for_e2e!()
    :ok
  end

  def ensure_app_started! do
    case Application.ensure_all_started(:hydra_srt) do
      {:ok, _} -> :ok
      {:error, {:already_started, :hydra_srt}} -> :ok
      other -> raise "Failed to start :hydra_srt application for E2E: #{inspect(other)}"
    end
  end

  def ensure_executables! do
    for exe <- ["ffmpeg", "srt-live-transmit"] do
      case System.find_executable(exe) do
        nil -> raise ExUnit.AssertionError, message: "E2E requires #{exe} in PATH"
        _path -> :ok
      end
    end

    :ok
  end

  def ffmpeg_supports_srt_encryption? do
    # Some ffmpeg/libsrt builds accept the passphrase options syntactically but
    # fail only when an encrypted connection is actually attempted.
    #
    # Probe by doing a tiny loopback transfer over SRT with passphrase enabled.
    # If either side exits non-zero, we consider encryption unsupported.
    port = tcp_free_port!()
    sink_file = tmp_file!("ffmpeg_enc_probe_sink", "ts")

    rx =
      start_port!(
        "ffmpeg",
        [
          "-hide_banner",
          "-loglevel",
          "error",
          "-y",
          "-i",
          "srt://127.0.0.1:#{port}?mode=listener&passphrase=probe_pass&pbkeylen=16",
          "-t",
          "1",
          "-c",
          "copy",
          "-f",
          "mpegts",
          sink_file
        ]
      )

    # Give listener a moment to bind.
    Process.sleep(250)

    tx =
      start_port!(
        "ffmpeg",
        [
          "-hide_banner",
          "-loglevel",
          "error",
          "-re",
          "-f",
          "lavfi",
          "-i",
          "testsrc2=size=320x240:rate=15",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:sample_rate=48000",
          "-t",
          "1",
          "-c:v",
          "libx264",
          "-preset",
          "veryfast",
          "-tune",
          "zerolatency",
          "-pix_fmt",
          "yuv420p",
          "-g",
          "30",
          "-c:a",
          "aac",
          "-b:a",
          "96k",
          "-ar",
          "48000",
          "-ac",
          "2",
          "-f",
          "mpegts",
          "srt://127.0.0.1:#{port}?mode=caller&passphrase=probe_pass&pbkeylen=16"
        ]
      )

    tx_status = await_exit_status!(tx, 15_000)
    rx_status = await_exit_status!(rx, 15_000)

    if is_integer(tx_status) and tx_status != 0, do: kill_port(tx)
    if is_integer(rx_status) and rx_status != 0, do: kill_port(rx)

    tx_status == 0 and rx_status == 0
  end

  def ensure_native_built! do
    {output, exit_code} = System.cmd("make", ["-C", "native"], stderr_to_stdout: true)

    if exit_code != 0 do
      raise "Failed to build native binary with `make -C native` (exit=#{exit_code}):\n#{output}"
    end

    binary = Path.expand("native/build/hydra_srt_pipeline")

    if File.exists?(binary),
      do: :ok,
      else: raise("Native binary not found at #{binary} after build")
  end

  def ensure_api_auth_config! do
    Application.put_env(:hydra_srt, :api_auth_username, "admin")
    Application.put_env(:hydra_srt, :api_auth_password, "password123")
    :ok
  end

  def ensure_cachex_started! do
    # In `HydraSrt.Application` Cachex is started only for distributed nodes.
    # E2E tests run on `:nonode@nohost`, but API auth still depends on `HydraSrt.Cache`.
    case Process.whereis(HydraSrt.Cache) do
      pid when is_pid(pid) ->
        :ok

      _ ->
        case Cachex.start_link(name: HydraSrt.Cache) do
          {:ok, _pid} -> :ok
          {:already_started, _pid} -> :ok
          other -> raise "Failed to start Cachex for E2E: #{inspect(other)}"
        end
    end
  end

  def ensure_repo_config_for_e2e! do
    if System.get_env("E2E") == "true" do
      db_path =
        System.get_env("E2E_DATABASE_PATH") ||
          Path.join(System.tmp_dir!(), "hydra_srt_e2e_#{System.unique_integer([:positive])}.db")

      System.put_env("E2E_DATABASE_PATH", db_path)

      current = Application.get_env(:hydra_srt, HydraSrt.Repo, [])

      updated =
        current
        |> Keyword.put(:database, db_path)
        |> Keyword.put(:pool, DBConnection.ConnectionPool)
        |> Keyword.put(:pool_size, 5)

      Application.put_env(:hydra_srt, HydraSrt.Repo, updated)
    end

    :ok
  end

  def ensure_repo_migrated_for_e2e! do
    if System.get_env("E2E") == "true" do
      migrations_path = Application.app_dir(:hydra_srt, "priv/repo/migrations")

      Ecto.Migrator.with_repo(HydraSrt.Repo, fn repo ->
        _ = Ecto.Migrator.run(repo, migrations_path, :up, all: true)
      end)
    end

    :ok
  end

  def kill_all_pipelines! do
    pipelines = HydraSrt.ProcessMonitor.list_pipeline_processes()

    Enum.each(pipelines, fn %{pid: pid} ->
      System.cmd("kill", ["-9", Integer.to_string(pid)])
    end)

    # Best-effort sweep in case ps parsing missed anything.
    System.cmd("pkill", ["-9", "-f", "hydra_srt_pipeline"])

    :ok
  end

  def ensure_endpoint_server_started! do
    if System.get_env("E2E") == "true" do
      current = Application.get_env(:hydra_srt, HydraSrtWeb.Endpoint, [])
      updated = Keyword.put(current, :server, true)
      Application.put_env(:hydra_srt, HydraSrtWeb.Endpoint, updated)

      pid = Process.whereis(HydraSrtWeb.Endpoint)

      if is_pid(pid) do
        # Restart endpoint so it picks up server=true and boots Cowboy listener.
        # We must use the supervision tree to restart it properly.
        Supervisor.terminate_child(HydraSrt.Supervisor, HydraSrtWeb.Endpoint)
        {:ok, _} = Supervisor.restart_child(HydraSrt.Supervisor, HydraSrtWeb.Endpoint)
      end

      wait_until(fn -> is_pid(Process.whereis(HydraSrtWeb.Endpoint)) end, 5_000, 50)
      wait_for_healthcheck!(base_url(), 10_000)
      :ok
    else
      raise ExUnit.AssertionError, message: "Set E2E=true to run E2E tests"
    end
  end

  def base_url do
    host = System.get_env("E2E_HOST", @default_host)
    port = System.get_env("E2E_PORT", "#{@default_port}") |> String.to_integer()
    "http://#{host}:#{port}"
  end

  def wait_for_healthcheck!(base_url, timeout_ms) do
    wait_until(
      fn ->
        case http_raw(:get, base_url <> "/health/", [], "") do
          {:ok, 200, _headers, _body} -> true
          _ -> false
        end
      end,
      timeout_ms,
      100
    )

    :ok
  end

  def api_login!(base_url, user, password) do
    body = Jason.encode!(%{"login" => %{"user" => user, "password" => password}})

    {:ok, 200, _headers, resp} =
      http_raw(:post, base_url <> "/api/login", [{"content-type", "application/json"}], body)

    token = Jason.decode!(resp) |> Map.fetch!("token")
    token
  end

  def api_create_route!(base_url, token, route_params) when is_map(route_params) do
    body = Jason.encode!(%{"route" => route_params})

    {:ok, 201, _headers, resp} =
      http_raw(:post, base_url <> "/api/routes", auth_headers(token), body)

    Jason.decode!(resp) |> get_in(["data", "id"])
  end

  def api_create_destination!(base_url, token, route_id, dest_params) when is_map(dest_params) do
    body = Jason.encode!(%{"destination" => dest_params})

    {:ok, 201, _headers, _resp} =
      http_raw(
        :post,
        base_url <> "/api/routes/#{route_id}/destinations",
        auth_headers(token),
        body
      )

    :ok
  end

  def api_start_route!(base_url, token, route_id) do
    {:ok, 200, _headers, _resp} =
      http_raw(:get, base_url <> "/api/routes/#{route_id}/start", auth_headers(token), "")

    :ok
  end

  def api_stop_route(base_url, token, route_id) do
    http_raw(:get, base_url <> "/api/routes/#{route_id}/stop", auth_headers(token), "")
  end

  def api_delete_route(base_url, token, route_id) do
    http_raw(:delete, base_url <> "/api/routes/#{route_id}", auth_headers(token), "")
  end

  def auth_headers(token) do
    [
      {"authorization", "Bearer " <> token},
      {"content-type", "application/json"}
    ]
  end

  def http_raw(method, url, headers, body) do
    :inets.start()
    :ssl.start()

    request =
      case method do
        :get -> {String.to_charlist(url), headers_to_charlist(headers)}
        :delete -> {String.to_charlist(url), headers_to_charlist(headers)}
        _ -> {String.to_charlist(url), headers_to_charlist(headers), ~c"application/json", body}
      end

    opts = [timeout: 20_000, connect_timeout: 5_000]

    case :httpc.request(method, request, opts, body_format: :binary) do
      {:ok, {{_http, status, _reason}, resp_headers, resp_body}} ->
        {:ok, status, resp_headers, resp_body}

      {:ok, {{_http, status}, resp_headers, resp_body}} ->
        {:ok, status, resp_headers, resp_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def headers_to_charlist(headers) do
    Enum.map(headers, fn {k, v} ->
      {String.to_charlist(k), String.to_charlist(v)}
    end)
  end

  def udp_free_port! do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
    {:ok, {_ip, port}} = :inet.sockname(socket)
    :ok = :gen_udp.close(socket)
    port
  end

  def tcp_free_port! do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  def tmp_file!(prefix, ext) do
    name = "#{prefix}_#{System.unique_integer([:positive])}.#{ext}"
    Path.join(System.tmp_dir!(), name)
  end

  def start_port!(exe, args) when is_binary(exe) and is_list(args) do
    exec = System.find_executable(exe) || raise "Executable not found: #{exe}"

    port =
      Port.open({:spawn_executable, String.to_charlist(exec)}, [
        :binary,
        :exit_status,
        :stream,
        :stderr_to_stdout,
        :hide,
        args: args
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} when is_integer(pid) -> pid
        _ -> nil
      end

    %{port: port, os_pid: os_pid, exe: exe, args: args}
  end

  def start_port_logged!(exe, args, tag) when is_binary(tag) do
    owner = self()
    proc = start_port!(exe, args)
    logger_pid = spawn_link(__MODULE__, :port_log_loop, [proc.port, tag, owner])
    true = Port.connect(proc.port, logger_pid)
    Map.put(proc, :tag, tag)
  end

  def port_log_loop(port, tag, owner) when is_port(port) and is_binary(tag) and is_pid(owner) do
    receive do
      {^port, {:data, data}} when is_binary(data) ->
        String.split(data, "\n")
        |> Enum.each(fn line ->
          if line != "" do
            Logger.warning("#{tag}: #{line}")
            maybe_emit_srt_stats(tag, line, owner)
          end
        end)

        port_log_loop(port, tag, owner)

      {^port, {:exit_status, status}} ->
        Logger.warning("#{tag}: exit_status=#{status}")
        send(owner, {:port_exit_status, tag, status})
        :ok

      {:EXIT, ^port, reason} ->
        Logger.warning("#{tag}: port_exit=#{inspect(reason)}")
        send(owner, {:port_exit_status, tag, reason})
        :ok
    after
      30_000 ->
        :ok
    end
  end

  def maybe_emit_srt_stats(tag, line, owner)
      when is_binary(tag) and is_binary(line) and is_pid(owner) do
    # srt-live-transmit prints lines like:
    # "PACKETS     SENT:           0  RECEIVED:          1053"
    if String.contains?(tag, "srt-live-transmit") and String.contains?(line, "PACKETS") and
         String.contains?(line, "RECEIVED:") do
      case Regex.run(~r/RECEIVED:\s+(\d+)/, line) do
        [_, received_str] ->
          case Integer.parse(received_str) do
            {received, _} ->
              send(owner, {:srt_packets_received, received})

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    end

    :ok
  end

  def await_srt_packets_received(min_packets, timeout_ms)
      when is_integer(min_packets) and is_integer(timeout_ms) do
    start = System.monotonic_time(:millisecond)
    do_await_srt_packets_received(min_packets, start, timeout_ms)
  end

  def do_await_srt_packets_received(min_packets, start_ms, timeout_ms) do
    remaining = timeout_ms - (System.monotonic_time(:millisecond) - start_ms)

    if remaining <= 0 do
      nil
    else
      receive do
        {:srt_packets_received, received} when received >= min_packets ->
          received

        {:srt_packets_received, _received} ->
          do_await_srt_packets_received(min_packets, start_ms, timeout_ms)
      after
        min(250, remaining) ->
          do_await_srt_packets_received(min_packets, start_ms, timeout_ms)
      end
    end
  end

  def await_tag_exit_status(tag, timeout_ms) when is_binary(tag) and is_integer(timeout_ms) do
    receive do
      {:port_exit_status, ^tag, status} -> status
    after
      timeout_ms -> nil
    end
  end

  def await_exit_status!(%{port: port}, timeout_ms)
      when is_port(port) and is_integer(timeout_ms) do
    receive do
      {^port, {:exit_status, status}} -> status
    after
      timeout_ms -> nil
    end
  end

  def kill_port(%{port: port} = proc) when is_port(port) do
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} when is_integer(pid) -> pid
        _ -> proc.os_pid
      end

    if is_integer(os_pid) do
      System.cmd("kill", ["-9", "#{os_pid}"])
    end

    try do
      Port.close(port)
    rescue
      _ -> :ok
    end

    :ok
  end

  def start_udp_counter!(port) when is_integer(port) do
    {:ok, sock} = :gen_udp.open(port, [:binary, active: true, ip: {0, 0, 0, 0}])
    parent = self()
    pid = spawn_link(__MODULE__, :udp_counter_loop, [sock, 0, parent])
    :ok = :gen_udp.controlling_process(sock, pid)
    %{pid: pid, sock: sock, port: port}
  end

  def udp_counter_loop(sock, bytes, parent) do
    receive do
      {:udp, ^sock, _ip, _port, data} when is_binary(data) ->
        udp_counter_loop(sock, bytes + byte_size(data), parent)

      {:get_bytes, from} when is_pid(from) ->
        send(from, {:udp_bytes, bytes})
        udp_counter_loop(sock, bytes, parent)

      :stop ->
        :gen_udp.close(sock)
        send(parent, {:udp_bytes_final, bytes})
        :ok
    after
      30_000 ->
        :gen_udp.close(sock)
        send(parent, {:udp_bytes_final, bytes})
        :ok
    end
  end

  def get_udp_bytes!(%{pid: pid}) when is_pid(pid) do
    send(pid, {:get_bytes, self()})

    receive do
      {:udp_bytes, bytes} -> bytes
    after
      1_000 -> 0
    end
  end

  def stop_udp_counter!(%{pid: pid} = counter) when is_pid(pid) do
    send(pid, :stop)

    receive do
      {:udp_bytes_final, bytes} ->
        Map.put(counter, :bytes, bytes)
    after
      2_000 ->
        Map.put(counter, :bytes, 0)
    end
  end

  def wait_until(fun, timeout_ms, interval_ms) when is_function(fun, 0) do
    start = System.monotonic_time(:millisecond)
    do_wait_until(fun, start, timeout_ms, interval_ms)
  end

  def do_wait_until(fun, start_ms, timeout_ms, interval_ms) do
    if fun.() do
      :ok
    else
      now = System.monotonic_time(:millisecond)

      if now - start_ms > timeout_ms do
        raise "Timeout after #{timeout_ms}ms"
      else
        Process.sleep(interval_ms)
        do_wait_until(fun, start_ms, timeout_ms, interval_ms)
      end
    end
  end

  def wait_for_file_size!(path, min_bytes, timeout_ms) do
    wait_until(
      fn ->
        case File.stat(path) do
          {:ok, stat} -> stat.size >= min_bytes
          _ -> false
        end
      end,
      timeout_ms,
      100
    )
  end

  def file_size(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      _ -> 0
    end
  end
end

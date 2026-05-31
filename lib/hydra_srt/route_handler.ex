defmodule HydraSrt.RouteHandler do
  @moduledoc false

  require Logger
  @behaviour :gen_statem
  @normal_port_exit_reasons [:normal, :epipe]
  @retry_restart_interval_ms 5_000

  alias HydraSrt.Db
  alias HydraSrt.Helpers
  alias HydraSrt.SystemInterfaces
  alias HydraSrt.Stats.EventLogger
  import Bitwise

  def start_link(args), do: :gen_statem.start_link(__MODULE__, args, [])

  def switch_source(pid, source_id, reason \\ "manual"),
    do: :gen_statem.cast(pid, {:switch_source, source_id, reason})

  def switch_source_sync(pid, source_id, reason \\ "manual", timeout \\ 15_000),
    do: :gen_statem.call(pid, {:switch_source, source_id, reason}, timeout)

  @impl true
  def callback_mode, do: [:handle_event_function]

  @impl true
  def init(args) do
    Process.flag(:trap_exit, true)
    Logger.info("RouteHandler: init: #{inspect(args)}")

    {:ok, route} = Db.get_route(args.id, true)

    data = %{
      id: args.id,
      port: nil,
      route: route,
      port_buffer: "",
      shutdown_reason: nil,
      active_source_id: route["active_source_id"],
      last_manual_source_id: nil,
      zero_bitrate_ticks: 0,
      reconnecting_since_ms: nil,
      cooldown_until: nil,
      primary_stable_since_ms: nil,
      last_primary_probe_ms: nil,
      primary_probe_inflight?: false,
      retry_scheduled?: false,
      recovering?: false
    }

    {:ok, :start, data, {:next_event, :internal, :start}}
  end

  @impl true
  def handle_event(:internal, :start, _state, data) do
    Logger.info("RouteHandler: starting route #{data.id}")

    port =
      open_and_initialize_native_pipeline(data.route, data.id, data.active_source_id)

    case port do
      {:ok, port} ->
        HydraSrt.mark_route_started(data.id)

        {:next_state, :started,
         %{data | port: port, zero_bitrate_ticks: 0, reconnecting_since_ms: nil}}

      {:error, reason} ->
        Logger.error("RouteHandler: Failed to start: #{inspect(reason)}")

        next_data =
          data
          |> mark_restarting_runtime()
          |> schedule_retry_restart()

        {:keep_state, next_data}
    end
  end

  def handle_event(:info, {port, {:data, info}}, _state, %{port: port} = data)
      when is_binary(info) do
    new_data = consume_port_output(info, data)
    {:keep_state, new_data}
  end

  def handle_event(:info, {port, {:data, {:eol, info}}}, _state, %{port: port} = data)
      when is_binary(info) do
    new_data = consume_port_output(info <> "\n", data)
    {:keep_state, new_data}
  end

  def handle_event(:info, {port, {:data, {:noeol, info}}}, _state, %{port: port} = data)
      when is_binary(info) do
    new_data = consume_port_output(info, data)
    {:keep_state, new_data}
  end

  # Ignore stale port data after a source switch; old processes may still flush output.
  def handle_event(:info, {_stale_port, {:data, _info}}, _state, data) do
    {:keep_state, data}
  end

  def handle_event(:info, {port, {:exit_status, status}}, _state, %{port: port} = data) do
    log_fun = if status == 0, do: &Logger.info/1, else: &Logger.error/1
    log_fun.("RouteHandler: native pipeline exited with status #{status}")

    if status == 0 do
      {:stop, :normal, %{data | shutdown_reason: {:port_exit, 0}}}
    else
      next_data =
        data
        |> mark_restarting_runtime()
        |> Map.put(:port, nil)
        |> schedule_retry_restart()

      {:keep_state, next_data}
    end
  end

  def handle_event(:info, {_stale_port, {:exit_status, _status}}, _state, data) do
    {:keep_state, data}
  end

  def handle_event(:info, {:EXIT, port, reason}, _state, %{port: port} = data) do
    Logger.info("RouteHandler: port exit #{inspect(reason)}")

    if reason == :epipe do
      kill_stale_pipeline_processes(data.id, "epipe")
    end

    if reason in @normal_port_exit_reasons do
      {:stop, :normal, %{data | shutdown_reason: {:port_exit, reason}}}
    else
      next_data =
        data
        |> mark_restarting_runtime()
        |> Map.put(:port, nil)
        |> schedule_retry_restart()

      {:keep_state, next_data}
    end
  end

  def handle_event(:info, {:EXIT, _stale_port, _reason}, _state, data) do
    {:keep_state, data}
  end

  def handle_event(:info, :retry_start, _state, data) do
    next_data =
      data
      |> Map.put(:retry_scheduled?, false)
      |> retry_pipeline_start()

    {:keep_state, next_data}
  end

  def handle_event(:cast, {:switch_source, source_id, reason}, _state, data)
      when is_binary(source_id) and is_binary(reason) do
    case failover_to_source(data, source_id, reason) do
      {:ok, next_data} -> {:keep_state, next_data}
      {:error, _reason, next_data} -> {:keep_state, next_data}
      {:error, _reason} -> {:keep_state, data}
    end
  end

  def handle_event({:call, from}, {:switch_source, source_id, reason}, _state, data)
      when is_binary(source_id) and is_binary(reason) do
    case failover_to_source(data, source_id, reason) do
      {:ok, next_data} -> {:keep_state, next_data, [{:reply, from, :ok}]}
      {:error, reason, next_data} -> {:keep_state, next_data, [{:reply, from, {:error, reason}}]}
      {:error, reason} -> {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event(
        :info,
        {:primary_probe_result, probed_source_id, result, probe_now},
        _state,
        data
      )
      when is_binary(probed_source_id) do
    mode = backup_mode(data.route)
    sources = get_in(data, [:route, "sources"]) || []
    primary = Enum.find(sources, &(&1["position"] == 0))
    primary_stable_ms = backup_primary_stable_ms(data.route)

    cond do
      mode != "active" or is_nil(primary) ->
        {:keep_state, %{data | primary_probe_inflight?: false}}

      primary["id"] != probed_source_id or data.active_source_id == primary["id"] ->
        {:keep_state, %{data | primary_probe_inflight?: false}}

      true ->
        next_data =
          case result do
            {:ok, _} ->
              stable_since = data.primary_stable_since_ms || probe_now

              if max(probe_now - stable_since, 0) >= primary_stable_ms do
                case failover_to_source(data, primary["id"], "primary_recovered") do
                  {:ok, switched} ->
                    %{switched | primary_stable_since_ms: nil, last_primary_probe_ms: probe_now}

                  {:error, _} ->
                    %{
                      data
                      | primary_stable_since_ms: stable_since,
                        last_primary_probe_ms: probe_now
                    }
                end
              else
                %{data | primary_stable_since_ms: stable_since, last_primary_probe_ms: probe_now}
              end

            {:error, reason} ->
              EventLogger.log_source_probe_failed(data.id, primary["id"], reason)
              %{data | primary_stable_since_ms: nil, last_primary_probe_ms: probe_now}
          end

        {:keep_state, %{next_data | primary_probe_inflight?: false}}
    end
  end

  def handle_event(type, content, state, data) do
    Logger.error(
      "RouteHandler: Undefined msg: #{inspect([{"type", type}, {"content", content}, {"state", state}, {"data", data}],
      pretty: true)}"
    )

    :keep_state_and_data
  end

  @impl true
  def terminate(reason, _state, %{id: id, shutdown_reason: shutdown_reason})
      when not is_nil(shutdown_reason) do
    Logger.info("RouteHandler: reason: #{inspect(reason)}")
    mark_route_terminated(id, shutdown_reason)
    :ok
  end

  def terminate(reason, _state, %{port: port, id: id}) when is_port(port) do
    Logger.info("RouteHandler: reason: #{inspect(reason)} Closing port #{inspect(port)}")
    close_port(port)
    mark_route_terminated(id, reason)
    :ok
  end

  def terminate(reason, _state, data) do
    Logger.info("RouteHandler: reason: #{inspect(reason)}")
    mark_route_terminated(data.id, reason)
    :ok
  end

  defp open_and_initialize_native_pipeline(route, route_id, source_id) do
    route
    |> start_native_pipeline()
    |> initialize_native_pipeline(route_id, source_id, true)
  end

  defp initialize_native_pipeline(port, route_id, source_id, retry_on_closed?) do
    Logger.info("RouteHandler: Started port: #{inspect(port)}")

    case send_initial_command(port, route_id, source_id) do
      :ok ->
        {:ok, port}

      {:error, :closed} when retry_on_closed? ->
        kill_stale_pipeline_processes(route_id, "failed_start_closed")

        route_id
        |> Db.get_route(true)
        |> case do
          {:ok, route} ->
            route
            |> start_native_pipeline()
            |> initialize_native_pipeline(route_id, source_id, false)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("RouteHandler: Failed to start: #{inspect(reason)}")
        kill_stale_pipeline_processes(route_id, "failed_start")
        {:error, reason}
    end
  end

  defp start_native_pipeline(route) do
    binary_path = get_binary_path()
    args = [to_string(route["id"])]

    base_opts = [
      :stderr_to_stdout,
      :use_stdio,
      :binary,
      :exit_status,
      :stream,
      args: Enum.map(args, &String.to_charlist/1)
    ]

    env_opts =
      case route["gstDebug"] do
        debug when is_binary(debug) and debug != "" ->
          [env: [{~c"GST_DEBUG", String.to_charlist(debug)}, {~c"GST_DEBUG_NO_COLOR", ~c"1"}]]

        _ ->
          [env: [{~c"GST_DEBUG_NO_COLOR", ~c"1"}]]
      end

    Logger.info(
      "RouteHandler: start_native_pipeline: #{binary_path} #{Enum.join(args, " ")}: #{inspect(route["gstDebug"])}"
    )

    Port.open({:spawn_executable, String.to_charlist(binary_path)}, base_opts ++ env_opts)
  end

  defp get_binary_path do
    Path.join([:code.priv_dir(:hydra_srt), "native", "hydra_srt_pipeline"])
  end

  defp send_initial_command(port, route_id, source_id) do
    with {:ok, params} <- route_data_to_params(route_id, source_id),
         {:ok, params} <- Jason.encode(params),
         payload = params <> "\n",
         _ = Logger.info("RouteHandler: initial command payload: #{params}"),
         :ok <- command_port(port, payload) do
      Logger.info("RouteHandler: sent initial command")
      :ok
    else
      {:error, reason} ->
        Logger.error("RouteHandler: send_initial_command failed: #{inspect(reason)}")
        {:error, reason}

      error ->
        Logger.error("RouteHandler: send_initial_command failed: #{inspect(error)}")
        {:error, error}
    end
  end

  defp command_port(port, payload) when is_port(port) and is_binary(payload) do
    case Port.info(port) do
      nil ->
        {:error, :closed}

      _info ->
        try do
          Port.command(port, payload)
          :ok
        rescue
          ArgumentError -> {:error, :closed}
        end
    end
  end

  defp command_port(_port, _payload), do: {:error, :invalid_port}

  defp close_port(port) do
    try do
      if not is_port(port) or is_nil(Port.info(port)) do
        :ok
      else
        case Port.info(port, :os_pid) do
          {:os_pid, pid} when is_integer(pid) ->
            Logger.info("RouteHandler: Killing external process with PID #{pid}")
            Helpers.sys_kill(pid)

          _ ->
            Logger.warning("RouteHandler: Could not get OS PID, relying on Port.close/1")
        end

        Port.close(port)
      end
    rescue
      ArgumentError ->
        :ok

      error ->
        Logger.error("RouteHandler: Error closing port: #{inspect(error)}")
    end
  end

  def consume_port_output(chunk, data) when is_binary(chunk) and is_map(data) do
    [buffer | completed_lines] =
      (data.port_buffer <> chunk)
      |> String.split("\n")
      |> Enum.reverse()

    completed_lines
    |> Enum.reverse()
    |> Enum.reduce(%{data | port_buffer: buffer}, fn line, acc ->
      process_port_line(String.trim_trailing(line, "\r"), acc)
    end)
  end

  defp process_port_line("", data), do: data

  defp process_port_line("route_id:" <> route_id, data) do
    if route_id != data.id do
      Logger.warning("RouteHandler: route_id mismatch from native pipeline: #{inspect(route_id)}")
    end

    data
  end

  defp process_port_line("stats_source_stream_id:" <> _stream_id, data), do: data

  defp process_port_line("{" <> _ = json, data) do
    case parse_native_json_line(json) do
      {:pipeline_status, status, reason} ->
        Logger.info("RouteHandler: pipeline_status=#{status} reason=#{inspect(reason)}")

        data =
          case status do
            "reconnecting" ->
              EventLogger.log_pipeline_reconnecting(data.id, data.active_source_id)
              maybe_failover(data, :reconnecting)

            "processing" ->
              %{data | reconnecting_since_ms: nil}

            "failed" ->
              EventLogger.log_pipeline_failed(
                data.id,
                data.active_source_id,
                reason || "failed",
                "Pipeline reported failed status"
              )

              schedule_retry_restart(data)

            _ ->
              data
          end

        case normalize_runtime_status(status, reason, data) do
          {:update, normalized_status} ->
            HydraSrt.set_route_runtime_status(data.id, normalized_status)
            data

          :ignore ->
            data
        end

      {:stats, stats} ->
        # Logger.info("RouteHandler: pipeline stats: #{json}")
        publish_stats(data.id, stats, %{
          active_source_id: data.active_source_id,
          active_source_position: active_source_position(data.route, data.active_source_id)
        })

        data
        |> maybe_handle_zero_bitrate(stats)
        |> maybe_probe_primary_recovery()

      {:srt_access, access_event} ->
        publish_srt_access_log(data.id, access_event)
        data

      :unknown ->
        Logger.warning("RouteHandler: unknown native json line: #{inspect(json)}")
        data
    end
  end

  defp process_port_line(line, data) do
    Logger.debug("RouteHandler: pipeline: #{inspect(line)}")

    case HydraSrt.Stats.PipelineLogParser.parse(line) do
      {:ok, log} ->
        log = Map.put(log, :route_id, data.id)

        Phoenix.PubSub.broadcast(
          HydraSrt.PubSub,
          "pipeline_logs",
          {:pipeline_log, log}
        )

      :error ->
        :ok = HydraSrt.PipelineLogTelemetry.emit_unparsed(data.id)
    end

    data
  end

  defp maybe_handle_zero_bitrate(data, stats) do
    bytes_in = get_in(stats, ["source", "bytes_in_per_sec"])

    if is_number(bytes_in) and bytes_in == 0 do
      data
      |> Map.update!(:zero_bitrate_ticks, &(&1 + 1))
      |> maybe_failover(:zero_bitrate)
    else
      if data.recovering? do
        HydraSrt.set_route_runtime_status(data.id, "processing")
        %{data | zero_bitrate_ticks: 0, recovering?: false}
      else
        %{data | zero_bitrate_ticks: 0}
      end
    end
  end

  defp maybe_probe_primary_recovery(data) do
    mode = backup_mode(data.route)

    with true <- mode == "active",
         false <- in_cooldown?(data.cooldown_until, now_ms()),
         sources when is_list(sources) <- get_in(data, [:route, "sources"]),
         %{} = primary <- Enum.find(sources, &(&1["position"] == 0)),
         true <- is_binary(primary["id"]) and data.active_source_id != primary["id"] do
      probe_interval_ms = backup_probe_interval_ms(data.route)
      now = now_ms()

      should_probe? =
        is_nil(data.last_primary_probe_ms) or
          max(now - data.last_primary_probe_ms, 0) >= probe_interval_ms

      if should_probe? and not data.primary_probe_inflight? do
        probe_module = Application.get_env(:hydra_srt, :source_probe_module, HydraSrt.SourceProbe)
        route_handler = self()
        primary_id = primary["id"]

        Task.start(fn ->
          result = probe_module.probe(primary)
          send(route_handler, {:primary_probe_result, primary_id, result, now})
        end)

        %{data | primary_probe_inflight?: true}
      else
        data
      end
    else
      _ -> data
    end
  end

  defp maybe_failover(data, reason) when reason in [:zero_bitrate, :reconnecting, :failed] do
    now_ms = now_ms()

    reconnecting_elapsed_ms =
      case data.reconnecting_since_ms do
        nil -> 0
        started when is_integer(started) -> max(now_ms - started, 0)
      end

    reconnecting_since_ms =
      if reason == :reconnecting do
        data.reconnecting_since_ms || now_ms
      else
        data.reconnecting_since_ms
      end

    eval_data =
      data
      |> Map.put(:now_ms, now_ms)
      |> Map.put(:reconnecting_elapsed_ms, reconnecting_elapsed_ms)

    if should_trigger_failover?(eval_data, reason) do
      case next_source_for_failover(data) do
        nil ->
          data

        next_source ->
          case failover_to_source(data, next_source["id"], Atom.to_string(reason)) do
            {:ok, next_data} -> next_data
            {:error, _reason, next_data} -> next_data
            {:error, _} -> data
          end
      end
    else
      %{data | reconnecting_since_ms: reconnecting_since_ms}
    end
  end

  defp next_source_for_failover(data) do
    mode = backup_mode(data.route)
    sources = get_in(data, [:route, "sources"]) || []

    case next_enabled_source(sources, data.active_source_id, mode) do
      %{"id" => id} = source when is_binary(id) -> source
      _ -> nil
    end
  end

  defp failover_to_source(data, source_id, reason) do
    route_id = data.id

    with {:ok, route} <- Db.get_route(route_id, true),
         {:ok, source_record} <- source_record_from_route(route, source_id),
         true <- source_record["enabled"] == true or {:error, :disabled_source} do
      persist_reason = switch_reason_for_persist(route, source_id, reason, data)
      next_data = maybe_mark_restarting_before_switch(data, reason)

      with :ok <- close_existing_port(next_data.port) do
        case open_and_initialize_native_pipeline(route, route_id, source_id) do
          {:ok, port} ->
            case Db.set_route_active_source(route_id, source_id, persist_reason) do
              {:ok, _route} ->
                cooldown_ms = backup_cooldown_ms(route)

                last_manual_source_id =
                  if reason == "manual" do
                    source_id
                  else
                    data[:last_manual_source_id]
                  end

                {:ok,
                 %{
                   next_data
                   | route: route,
                     port: port,
                     active_source_id: source_id,
                     last_manual_source_id: last_manual_source_id,
                     zero_bitrate_ticks: 0,
                     reconnecting_since_ms: nil,
                     cooldown_until: now_ms() + cooldown_ms,
                     primary_stable_since_ms: nil,
                     primary_probe_inflight?: false,
                     recovering?: true
                 }}

              {:error, reason} ->
                close_existing_port(port)

                failed_data =
                  next_data
                  |> Map.put(:port, nil)
                  |> schedule_retry_restart()

                {:error, reason, failed_data}
            end

          {:error, reason} ->
            failed_data =
              next_data
              |> Map.put(:port, nil)
              |> schedule_retry_restart()

            {:error, reason, failed_data}
        end
      end
    else
      {:error, reason} ->
        Logger.warning(
          "RouteHandler: failover failed route_id=#{route_id} reason=#{inspect(reason)}"
        )

        {:error, reason}

      false ->
        {:error, :invalid_source}
    end
  end

  # Keep operator intent in `last_switch_reason` when automatic failovers bounce the pipeline
  # (same source, or return to a source the operator last chose via API "manual").
  defp switch_reason_for_persist(route, source_id, reason, data)
       when is_map(route) and is_map(data) and is_binary(source_id) and is_binary(reason) do
    current_active_id = Map.get(route, "active_source_id")
    prior = Map.get(route, "last_switch_reason")
    manual_id = data[:last_manual_source_id]

    cond do
      reason in ["manual", "primary_recovered"] ->
        reason

      reason in ["zero_bitrate", "reconnecting", "failed"] and is_binary(manual_id) and
          source_id == manual_id ->
        "manual"

      reason in ["zero_bitrate", "reconnecting", "failed"] and source_id == current_active_id and
          prior == "manual" ->
        "manual"

      true ->
        reason
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp close_existing_port(port) when is_port(port) do
    close_port(port)
    :ok
  end

  defp close_existing_port(_), do: :ok

  defp schedule_retry_restart(%{retry_scheduled?: true} = data), do: data

  defp schedule_retry_restart(data) do
    Process.send_after(self(), :retry_start, @retry_restart_interval_ms)
    %{data | retry_scheduled?: true}
  end

  defp mark_restarting_runtime(data) do
    case HydraSrt.set_route_runtime_status(data.id, "restarting") do
      {:ok, _route} ->
        :ok

      {:error, reason} ->
        Logger.warning("RouteHandler: failed to mark route restarting: #{inspect(reason)}")
    end

    %{data | recovering?: true}
  end

  defp retry_pipeline_start(data) do
    with {:ok, route} <- Db.get_route(data.id, true),
         {:ok, source_id} <- retry_source_id(route, data.active_source_id),
         :ok <- close_existing_port(data.port),
         {:ok, port} <- open_and_initialize_native_pipeline(route, data.id, source_id) do
      _ = Db.set_route_active_source(data.id, source_id, "failed")

      %{
        data
        | route: route,
          port: port,
          active_source_id: source_id,
          zero_bitrate_ticks: 0,
          reconnecting_since_ms: nil,
          cooldown_until: nil,
          primary_stable_since_ms: nil,
          primary_probe_inflight?: false,
          recovering?: true
      }
    else
      {:error, reason} ->
        Logger.warning(
          "RouteHandler: retry start failed route_id=#{data.id} reason=#{inspect(reason)}"
        )

        data
        |> Map.put(:port, nil)
        |> mark_restarting_runtime()
        |> schedule_retry_restart()
    end
  end

  defp retry_source_id(route, active_source_id)
       when is_map(route) and is_binary(active_source_id) do
    sources = Map.get(route, "sources", [])

    source_id =
      case next_enabled_source(sources, active_source_id, "active") do
        %{"id" => id} when is_binary(id) -> id
        _ -> active_source_id
      end

    case source_record_from_route(route, source_id) do
      {:ok, %{"enabled" => true}} -> {:ok, source_id}
      _ -> source_record_from_route(route, nil) |> map_source_record_to_id()
    end
  end

  defp retry_source_id(route, _active_source_id) when is_map(route) do
    source_record_from_route(route, nil) |> map_source_record_to_id()
  end

  defp map_source_record_to_id({:ok, %{"id" => id, "enabled" => true}}) when is_binary(id),
    do: {:ok, id}

  defp map_source_record_to_id(_), do: {:error, :no_enabled_source}

  defp maybe_mark_restarting_before_switch(data, reason)
       when reason in ["zero_bitrate", "reconnecting", "failed", "manual", "primary_recovered"] do
    mark_restarting_runtime(data)
  end

  defp maybe_mark_restarting_before_switch(data, _reason), do: data

  defp backup_mode(route), do: backup_value(route, "backup_mode", "passive")

  defp backup_switch_after_ms(route),
    do: backup_value(route, "backup_switch_after_ms", 3000)

  defp backup_cooldown_ms(route),
    do: backup_value(route, "backup_cooldown_ms", 10_000)

  defp backup_primary_stable_ms(route),
    do: backup_value(route, "backup_primary_stable_ms", 15_000)

  defp backup_probe_interval_ms(route),
    do: backup_value(route, "backup_probe_interval_ms", 5000)

  defp backup_value(route, flat_key, default) when is_map(route) do
    Map.get(route, flat_key) || default
  end

  @doc false
  def parse_native_json_line(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"event" => "pipeline_status", "status" => status} = payload}
      when is_binary(status) ->
        {:pipeline_status, status, Map.get(payload, "reason")}

      {:ok, %{"event" => "srt_access"} = payload} ->
        {:srt_access, payload}

      {:ok, %{"event" => _event}} ->
        :unknown

      {:ok, %{} = stats} ->
        {:stats, stats}

      _ ->
        :unknown
    end
  end

  @doc false
  def normalize_runtime_status(status, reason), do: normalize_runtime_status(status, reason, %{})
  def normalize_runtime_status("stopped", "failure", _data), do: :ignore
  def normalize_runtime_status("starting", _reason, _data), do: :ignore
  def normalize_runtime_status("processing", _reason, %{recovering?: true}), do: :ignore

  def normalize_runtime_status(status, _reason, _data) when is_binary(status),
    do: {:update, status}

  @doc false
  def publish_stats(route_id, %{} = stats, metadata \\ %{}) when is_binary(route_id) do
    stats
    |> stats_events(route_id)
    |> Enum.each(fn event ->
      Phoenix.PubSub.broadcast(HydraSrt.PubSub, "stats", {:stats, event})
    end)

    HydraSrt.Stats.Collector.ingest(route_id, stats, metadata)

    :ok
  end

  @doc false
  def publish_srt_access_log(route_id, %{} = access_event) when is_binary(route_id) do
    allowed? = access_event["allowed"] == true
    reason = access_event["reason"] || "unknown"
    ip = access_event["ip"] || "unknown"
    stream_id = access_event["stream_id"]

    log = %{
      route_id: route_id,
      gst_ts: nil,
      pid: nil,
      thread_id: nil,
      level: if(allowed?, do: "INFO", else: "WARN"),
      category: "srt_access",
      file: nil,
      line: nil,
      function: nil,
      element: "srtsrc",
      message: srt_access_message(ip, allowed?, reason, stream_id),
      dropped_count: nil
    }

    Phoenix.PubSub.broadcast(
      HydraSrt.PubSub,
      "pipeline_logs",
      {:pipeline_log, log}
    )
  end

  @doc false
  def srt_access_message(ip, allowed?, reason, nil) do
    "SRT caller ip=#{ip} allowed=#{allowed?} reason=#{reason}"
  end

  def srt_access_message(ip, allowed?, reason, stream_id) do
    "SRT caller ip=#{ip} stream_id=#{stream_id} allowed=#{allowed?} reason=#{reason}"
  end

  @doc false
  def stats_events(%{} = stats, route_id) when is_binary(route_id) do
    snapshot_events = [
      %{
        route_id: route_id,
        metric: "snapshot",
        stats: stats
      }
    ]

    in_events =
      case get_in(stats, ["source", "bytes_in_per_sec"]) do
        value when is_number(value) ->
          [
            %{
              route_id: route_id,
              direction: "in",
              metric: "bytes_per_sec",
              value: value
            }
          ]

        _ ->
          []
      end

    out_events =
      stats
      |> Map.get("destinations", [])
      |> Enum.flat_map(fn
        %{"id" => destination_id, "bytes_out_per_sec" => value}
        when is_binary(destination_id) and is_number(value) ->
          [
            %{
              route_id: route_id,
              destination_id: destination_id,
              direction: "out",
              metric: "bytes_per_sec",
              value: value
            }
          ]

        _ ->
          []
      end)

    snapshot_events ++ in_events ++ out_events
  end

  defp active_source_position(route, active_source_id)
       when is_map(route) and is_binary(active_source_id) do
    sources = Map.get(route, "sources", [])

    case Enum.find(sources, &(&1["id"] == active_source_id)) do
      %{"position" => position} when is_integer(position) -> position
      _ -> nil
    end
  end

  defp active_source_position(_route, _active_source_id), do: nil

  defp mark_route_terminated(route_id, {:port_exit, status}) when status not in [0, :normal] do
    HydraSrt.mark_route_terminated(route_id)
  end

  defp mark_route_terminated(route_id, reason)
       when reason in [
              :normal,
              :shutdown,
              {:port_exit, 0},
              {:port_exit, :normal},
              {:port_exit, :epipe}
            ] do
    HydraSrt.mark_route_stopped(route_id)
  end

  defp mark_route_terminated(route_id, {:startup_failed, _reason}) do
    HydraSrt.mark_route_failed(route_id)
  end

  defp mark_route_terminated(route_id, {:shutdown, _reason}) do
    HydraSrt.mark_route_stopped(route_id)
  end

  defp mark_route_terminated(route_id, _reason) do
    HydraSrt.mark_route_terminated(route_id)
  end

  defp kill_stale_pipeline_processes(route_id, context) do
    case HydraSrt.ProcessMonitor.kill_pipeline_processes_for_route(route_id) do
      {:ok, _results} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "RouteHandler: failed to kill stale pipeline processes route_id=#{route_id} context=#{context} reason=#{inspect(reason)}"
        )
    end
  end

  def route_data_to_params(route_id), do: route_data_to_params(route_id, nil)

  def route_data_to_params(route_id, source_id) do
    with {:ok, route} <- Db.get_route(route_id, true),
         {:ok, source_record} <- source_record_from_route(route, source_id),
         {:ok, source} <- source_from_record(source_record),
         {:ok, sinks} <- sinks_from_record(route) do
      {:ok, %{"source" => source, "sinks" => sinks}}
    end
  end

  @doc false
  def source_record_from_route(%{"sources" => sources}, source_id)
      when is_list(sources) and is_binary(source_id) do
    case Enum.find(sources, &(&1["id"] == source_id)) do
      nil -> {:error, :invalid_source}
      source -> {:ok, source}
    end
  end

  def source_record_from_route(%{"sources" => sources} = route, _source_id)
      when is_list(sources) do
    active_source_id = route["active_source_id"]

    source =
      Enum.find(sources, &(&1["id"] == active_source_id)) ||
        Enum.find(sources, &(&1["position"] == 0))

    case source do
      nil -> {:error, :invalid_source}
      source -> {:ok, source}
    end
  end

  def source_record_from_route(route, _source_id) when is_map(route) do
    raise ArgumentError,
          "route payload without \"sources\" is not supported after sources migration: #{inspect(route)}"
  end

  @spec sinks_from_record(map()) :: {:ok, list()} | {:error, term()}
  def sinks_from_record(%{"destinations" => destinations})
      when is_list(destinations) and destinations != [] do
    sinks =
      destinations
      |> Enum.filter(&destination_enabled?/1)
      |> Enum.reduce([], fn destination, acc ->
        case sink_from_record(destination) do
          {:ok, sink} ->
            [sink | acc]

          {:error, error} ->
            Logger.error(
              "RouteHandler: sink_from_record error: #{inspect(error)}, destination: #{inspect(destination)}"
            )

            acc
        end
      end)

    {:ok, sinks}
  end

  def sinks_from_record(_) do
    Logger.debug("RouteHandler: sinks_from_record: no destinations")
    {:ok, []}
  end

  defp destination_enabled?(destination) when is_map(destination) do
    destination["enabled"] == true or destination[:enabled] == true
  end

  @doc false
  def build_srt_uri(opts) when is_map(opts) do
    mode = Map.get(opts, "mode")

    localaddress =
      Map.get(
        opts,
        "localaddress",
        Application.get_env(:hydra_srt, :default_bind_ip, "127.0.0.1")
      )

    remote_address = Map.get(opts, "address") || Map.get(opts, "host")
    localport = Map.get(opts, "localport")
    remote_port = Map.get(opts, "port")

    query_params =
      %{}
      |> maybe_add_param(opts, "mode")
      |> maybe_add_param(opts, "passphrase")
      |> maybe_add_param(opts, "pbkeylen")
      |> maybe_add_param(opts, "poll-timeout")

    {host, port} =
      case mode do
        "caller" ->
          {remote_address || localaddress, remote_port || localport}

        "rendezvous" ->
          {remote_address || localaddress, remote_port || localport}

        _ ->
          {localaddress || remote_address, localport || remote_port}
      end

    URI.to_string(%URI{
      scheme: "srt",
      host: host,
      port: port,
      query: URI.encode_query(query_params)
    })
  end

  @doc false
  def build_srt_uri(_), do: nil

  @doc false
  def maybe_add_param(params, opts, key) when is_map(params) and is_map(opts) do
    case Map.get(opts, key) do
      nil -> params
      "" -> params
      value -> Map.put(params, key, value)
    end
  end

  def sink_from_record(%{"id" => id, "schema" => "SRT"} = destination) do
    opts = endpoint_options_from_record(destination)

    with {:ok, resolved_opts} <- resolve_interface_options(opts) do
      name = Map.get(destination, "name", id)

      # Native pipeline expects SRT properties directly on the element config (not a URI).
      {:ok,
       %{
         "type" => "srtsink",
         "uri" => build_srt_uri(resolved_opts),
         "hydra_destination_id" => id,
         "hydra_destination_name" => name,
         "hydra_destination_schema" => "SRT"
       }
       |> Map.merge(resolved_opts)}
    end
  end

  def sink_from_record(%{"id" => id, "schema" => "UDP"} = destination) do
    opts = endpoint_options_from_record(destination)

    with {:ok, resolved_opts} <- resolve_interface_options(opts) do
      name = Map.get(destination, "name", id)

      # Native pipeline expects `address` and `port` (it maps `address` -> udpsink host property).
      address = Map.get(resolved_opts, "address") || Map.get(resolved_opts, "host")
      port = Map.get(resolved_opts, "port")

      bind_address =
        Map.get(resolved_opts, "bind-address") || Map.get(resolved_opts, "localaddress")

      bind_address =
        if ipv6_address?(address) and link_local_ipv6?(bind_address) do
          nil
        else
          bind_address
        end

      {:ok,
       %{
         "type" => "udpsink",
         "address" => address,
         "host" => address,
         "port" => port,
         "bind-address" => bind_address,
         "multicast-iface" =>
           Map.get(resolved_opts, "multicast-iface") ||
             Map.get(resolved_opts, "interface_sys_name"),
         "hydra_destination_id" => id,
         "hydra_destination_name" => name,
         "hydra_destination_schema" => "UDP"
       }
       |> drop_nil_values()}
    end
  end

  def sink_from_record(_), do: {:error, :invalid_destination}

  def source_from_record(%{"schema" => "SRT"} = source) do
    opts = endpoint_options_from_record(source)

    with false <- map_size(opts) == 0,
         {:ok, resolved_opts} <- resolve_interface_options(opts) do
      # Native pipeline expects SRT properties directly on the element config (not a URI).
      {:ok,
       %{"type" => "srtsrc", "uri" => build_srt_uri(resolved_opts)} |> Map.merge(resolved_opts)}
    else
      true -> {:error, :invalid_source}
    end
  end

  def source_from_record(%{"schema" => "UDP"} = source) do
    opts = endpoint_options_from_record(source)

    with {:ok, resolved_opts} <- resolve_interface_options(opts) do
      # Native pipeline expects `address` and `port` for udpsrc.
      {:ok, %{"type" => "udpsrc"} |> Map.merge(resolved_opts)}
    end
  end

  def source_from_record(%{"schema" => "RTP"} = source) do
    opts = endpoint_options_from_record(source)

    with {:ok, resolved_opts} <- resolve_interface_options(opts) do
      # TS over RTP source uses udpsrc + rtpmp2tdepay in native pipeline.
      {:ok,
       %{"type" => "udpsrc", "hydra_source_schema" => "RTP"}
       |> Map.merge(resolved_opts)}
    end
  end

  def source_from_record(_), do: {:error, :invalid_source}

  @doc false
  def next_enabled_source(sources, current_id, mode)
      when is_list(sources) and mode in ["active", "passive", "disabled"] do
    if mode == "disabled" do
      nil
    else
      enabled_sources = Enum.filter(sources, &(Map.get(&1, "enabled") == true))

      case enabled_sources do
        [] ->
          nil

        _ ->
          current_index =
            Enum.find_index(enabled_sources, fn source -> Map.get(source, "id") == current_id end)

          case current_index do
            nil ->
              List.first(enabled_sources)

            index ->
              next_index = index + 1

              cond do
                next_index < length(enabled_sources) ->
                  Enum.at(enabled_sources, next_index)

                mode in ["active", "passive"] ->
                  List.first(enabled_sources)

                true ->
                  nil
              end
          end
      end
    end
  end

  @doc false
  def in_cooldown?(cooldown_until_ms, now_ms)
      when is_integer(cooldown_until_ms) and is_integer(now_ms),
      do: cooldown_until_ms > now_ms

  def in_cooldown?(_, _), do: false

  @doc false
  def should_trigger_failover?(data, reason)
      when is_map(data) and reason in [:zero_bitrate, :reconnecting, :failed] do
    mode = backup_mode(data.route)
    switch_after_ms = backup_switch_after_ms(data.route)
    cooldown_until = Map.get(data, :cooldown_until)
    now_ms = Map.get(data, :now_ms, 0)

    cond do
      mode == "disabled" ->
        false

      reason == :failed ->
        true

      in_cooldown?(cooldown_until, now_ms) ->
        false

      reason == :zero_bitrate ->
        zero_bitrate_ticks = Map.get(data, :zero_bitrate_ticks, 0)
        zero_bitrate_ticks * 1000 >= switch_after_ms

      reason == :reconnecting ->
        reconnecting_elapsed_ms = Map.get(data, :reconnecting_elapsed_ms, 0)
        reconnecting_elapsed_ms >= switch_after_ms
    end
  end

  @doc false
  def resolve_interface_options(opts) when is_map(opts) do
    case Map.get(opts, "interface_sys_name") do
      nil ->
        {:ok, opts}

      "" ->
        {:ok, opts}

      sys_name when is_binary(sys_name) ->
        with {:ok, bind_ip} <- resolve_interface_bind_ip(sys_name) do
          {:ok,
           opts
           |> Map.put("localaddress", bind_ip)
           |> Map.put("bind-address", bind_ip)
           |> Map.put("multicast-iface", sys_name)}
        else
          {:error, _reason} -> {:ok, opts}
          _ -> {:ok, opts}
        end
    end
  end

  def resolve_interface_options(_), do: {:error, :invalid_options}

  defp endpoint_options_from_record(record) when is_map(record) do
    %{}
    |> put_opt(record, "mode")
    |> put_opt(record, "interface_sys_name")
    |> put_opt(record, "localaddress")
    |> put_opt(record, "localport")
    |> put_opt(record, "address")
    |> put_opt(record, "port")
    |> put_opt(record, "host")
    |> put_opt(record, "latency")
    |> put_opt(record, "authentication")
    |> put_opt(record, "passphrase")
    |> put_opt(record, "pbkeylen")
    |> put_opt(record, "poll-timeout", "poll_timeout")
    |> put_opt(record, "auto-reconnect", "auto_reconnect")
    |> put_opt(record, "keep-listening", "keep_listening")
    |> put_opt(record, "multicast-iface", "multicast_iface")
    |> put_opt(record, "bind-address", "bind_address_option")
    |> put_opt(record, "buffer-size")
    |> put_opt(record, "buffer-size", "buffer_size")
    |> put_opt(record, "mtu")
    |> put_srt_access_opts(record)
  end

  defp put_opt(opts, record, key), do: put_opt(opts, record, key, key)

  defp put_opt(opts, record, key, source_key) do
    case Map.get(record, source_key) do
      nil -> opts
      value -> Map.put(opts, key, value)
    end
  end

  @doc false
  def put_srt_access_opts(opts, record) when is_map(opts) and is_map(record) do
    if record["limit_access"] == true do
      opts
      |> Map.put("hydra_limit_access", true)
      |> Map.put("hydra_allowed_list", normalize_access_list(record["allowed_list"]))
      |> Map.put("hydra_denied_list", normalize_access_list(record["denied_list"]))
    else
      opts
    end
  end

  @doc false
  def normalize_access_list(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def normalize_access_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> normalize_access_list(list)
      _ -> []
    end
  end

  def normalize_access_list(_), do: []

  @doc false
  def resolve_interface_bind_ip(sys_name) when is_binary(sys_name) do
    with {:error, _reason} <- resolve_interface_bind_ip_from_system(sys_name),
         {:error, _reason} <- resolve_interface_bind_ip_from_db(sys_name) do
      {:error, :not_found}
    else
      {:ok, bind_ip} -> {:ok, bind_ip}
    end
  end

  @doc false
  def resolve_interface_bind_ip_from_system(sys_name) when is_binary(sys_name) do
    system_interfaces_module =
      Application.get_env(:hydra_srt, :system_interfaces_module, SystemInterfaces)

    with {:ok, interfaces} <- system_interfaces_module.discover(),
         %{} = interface <- Enum.find(interfaces, &(&1["sys_name"] == sys_name)),
         ip when is_binary(ip) and ip != "" and ip != "-" <- Map.get(interface, "ip"),
         bind_ip when is_binary(bind_ip) and bind_ip != "" <- strip_cidr_suffix(ip) do
      {:ok, bind_ip}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc false
  def resolve_interface_bind_ip_from_db(sys_name) when is_binary(sys_name) do
    db_module = Application.get_env(:hydra_srt, :db_module, Db)

    with {:ok, interface} <- db_module.get_interface_by_sys_name(sys_name),
         ip when is_binary(ip) and ip != "" and ip != "-" <- Map.get(interface, "ip"),
         bind_ip when is_binary(bind_ip) and bind_ip != "" <- strip_cidr_suffix(ip) do
      {:ok, bind_ip}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc false
  def drop_nil_values(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc false
  def strip_cidr_suffix(ip) when is_binary(ip) do
    ip
    |> String.split("/", parts: 2)
    |> List.first()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp ipv6_address?(value) when is_binary(value) do
    case :inet.parse_address(to_charlist(value)) do
      {:ok, {_, _, _, _, _, _, _, _}} -> true
      _ -> false
    end
  end

  defp ipv6_address?(_), do: false

  defp link_local_ipv6?(value) when is_binary(value) do
    case :inet.parse_address(to_charlist(value)) do
      {:ok, {word0, _, _, _, _, _, _, _}} when is_integer(word0) ->
        (word0 &&& 0xFFC0) == 0xFE80

      _ ->
        false
    end
  end

  defp link_local_ipv6?(_), do: false

  def dummy_params do
    %{
      "source_type" => "srtsrc",
      "source_property" => "uri",
      "source_value" => "srt://127.0.0.1:4201?mode=listener",
      "sinks" => [
        %{
          "type" => "srtsink",
          "property" => "uri",
          "value" => "srt://127.0.0.1:4205?mode=listener"
        }
      ]
    }
    |> Jason.encode!()
  end
end

defmodule HydraSrt.RouteHandler do
  @moduledoc false

  require Logger
  @behaviour :gen_statem
  @normal_port_exit_reasons [:normal, :epipe]

  alias HydraSrt.Db
  alias HydraSrt.Helpers
  alias HydraSrt.Stats.EventLogger

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
      zero_bitrate_ticks: 0,
      reconnecting_since_ms: nil,
      cooldown_until: nil,
      primary_stable_since_ms: nil,
      last_primary_probe_ms: nil,
      primary_probe_inflight?: false
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
        {:stop, :normal, %{data | shutdown_reason: {:startup_failed, reason}}}
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
      {:stop, {:port_exit, status}, data}
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
      {:stop, {:port_exit, reason}, data}
    end
  end

  def handle_event(:info, {:EXIT, _stale_port, _reason}, _state, data) do
    {:keep_state, data}
  end

  def handle_event(:cast, {:switch_source, source_id, reason}, _state, data)
      when is_binary(source_id) and is_binary(reason) do
    case failover_to_source(data, source_id, reason) do
      {:ok, next_data} -> {:keep_state, next_data}
      {:error, _reason} -> {:keep_state, data}
    end
  end

  def handle_event({:call, from}, {:switch_source, source_id, reason}, _state, data)
      when is_binary(source_id) and is_binary(reason) do
    case failover_to_source(data, source_id, reason) do
      {:ok, next_data} -> {:keep_state, next_data, [{:reply, from, :ok}]}
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
    mode = get_in(data, [:route, "backup_config", "mode"]) || "passive"
    sources = get_in(data, [:route, "sources"]) || []
    primary = Enum.find(sources, &(&1["position"] == 0))
    primary_stable_ms = get_in(data, [:route, "backup_config", "primary_stable_ms"]) || 15_000

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
          [env: [{~c"GST_DEBUG", String.to_charlist(debug)}]]

        _ ->
          []
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
         :ok <- command_port(port, params <> "\n") do
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

  defp consume_port_output(chunk, data) do
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

              maybe_failover(data, :failed)

            _ ->
              data
          end

        case normalize_runtime_status(status, reason) do
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

      :unknown ->
        Logger.warning("RouteHandler: unknown native json line: #{inspect(json)}")
        data
    end
  end

  defp process_port_line(line, data) do
    Logger.warning("RouteHandler: pipeline: #{inspect(line)}")
    data
  end

  defp maybe_handle_zero_bitrate(data, stats) do
    bytes_in = get_in(stats, ["source", "bytes_in_per_sec"])

    if is_number(bytes_in) and bytes_in == 0 do
      data
      |> Map.update!(:zero_bitrate_ticks, &(&1 + 1))
      |> maybe_failover(:zero_bitrate)
    else
      %{data | zero_bitrate_ticks: 0}
    end
  end

  defp maybe_probe_primary_recovery(data) do
    mode = get_in(data, [:route, "backup_config", "mode"]) || "passive"

    with true <- mode == "active",
         false <- in_cooldown?(data.cooldown_until, now_ms()),
         sources when is_list(sources) <- get_in(data, [:route, "sources"]),
         %{} = primary <- Enum.find(sources, &(&1["position"] == 0)),
         true <- is_binary(primary["id"]) and data.active_source_id != primary["id"] do
      probe_interval_ms = get_in(data, [:route, "backup_config", "probe_interval_ms"]) || 5000
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
            {:error, _} -> data
          end
      end
    else
      %{data | reconnecting_since_ms: reconnecting_since_ms}
    end
  end

  defp next_source_for_failover(data) do
    mode = get_in(data, [:route, "backup_config", "mode"]) || "passive"
    sources = get_in(data, [:route, "sources"]) || []
    next_enabled_source(sources, data.active_source_id, mode)
  end

  defp failover_to_source(data, source_id, reason) do
    route_id = data.id

    with {:ok, route} <- Db.get_route(route_id, true),
         {:ok, source_record} <- source_record_from_route(route, source_id),
         true <- source_record["enabled"] == true or {:error, :disabled_source} do
      with :ok <- close_existing_port(data.port),
           {:ok, port} <- open_and_initialize_native_pipeline(route, route_id, source_id) do
        case Db.set_route_active_source(route_id, source_id, reason) do
          {:ok, _route} ->
            cooldown_ms = get_in(route, ["backup_config", "cooldown_ms"]) || 10_000

            {:ok,
             %{
               data
               | route: route,
                 port: port,
                 active_source_id: source_id,
                 zero_bitrate_ticks: 0,
                 reconnecting_since_ms: nil,
                 cooldown_until: now_ms() + cooldown_ms,
                 primary_stable_since_ms: nil,
                 primary_probe_inflight?: false
             }}

          {:error, reason} ->
            close_existing_port(port)
            {:error, reason}
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

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp close_existing_port(port) when is_port(port) do
    close_port(port)
    :ok
  end

  defp close_existing_port(_), do: :ok

  @doc false
  def parse_native_json_line(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"event" => "pipeline_status", "status" => status} = payload}
      when is_binary(status) ->
        {:pipeline_status, status, Map.get(payload, "reason")}

      {:ok, %{"event" => _event}} ->
        :unknown

      {:ok, %{} = stats} ->
        {:stats, stats}

      _ ->
        :unknown
    end
  end

  @doc false
  def normalize_runtime_status("stopped", "failure"), do: :ignore
  def normalize_runtime_status(status, _reason) when is_binary(status), do: {:update, status}

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
    HydraSrt.mark_route_stopped(route_id)
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

  def sink_from_record(%{"id" => id, "schema" => "SRT", "schema_options" => opts} = destination) do
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

  def sink_from_record(%{"id" => id, "schema" => "UDP", "schema_options" => opts} = destination) do
    with {:ok, resolved_opts} <- resolve_interface_options(opts) do
      name = Map.get(destination, "name", id)

      # Native pipeline expects `address` and `port` (it maps `address` -> udpsink host property).
      address = Map.get(resolved_opts, "address") || Map.get(resolved_opts, "host")
      port = Map.get(resolved_opts, "port")

      {:ok,
       %{
         "type" => "udpsink",
         "address" => address,
         "host" => address,
         "port" => port,
         "bind-address" =>
           Map.get(resolved_opts, "bind-address") || Map.get(resolved_opts, "localaddress"),
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

  def source_from_record(%{"schema" => "SRT", "schema_options" => opts}) do
    with {:ok, resolved_opts} <- resolve_interface_options(opts) do
      # Native pipeline expects SRT properties directly on the element config (not a URI).
      {:ok,
       %{"type" => "srtsrc", "uri" => build_srt_uri(resolved_opts)} |> Map.merge(resolved_opts)}
    end
  end

  def source_from_record(%{"schema" => "UDP", "schema_options" => opts}) do
    with {:ok, resolved_opts} <- resolve_interface_options(opts) do
      # Native pipeline expects `address` and `port` for udpsrc.
      {:ok, %{"type" => "udpsrc"} |> Map.merge(resolved_opts)}
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

                mode == "active" ->
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
    mode = get_in(data, [:route, "backup_config", "mode"]) || "passive"
    switch_after_ms = get_in(data, [:route, "backup_config", "switch_after_ms"]) || 3000
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
        with {:ok, interface} <- Db.get_interface_by_sys_name(sys_name),
             ip when is_binary(ip) and ip != "" and ip != "-" <- Map.get(interface, "ip"),
             bind_ip when is_binary(bind_ip) and bind_ip != "" <- strip_cidr_suffix(ip) do
          {:ok,
           opts
           |> Map.put("localaddress", bind_ip)
           |> Map.put("bind-address", bind_ip)
           |> Map.put("multicast-iface", sys_name)}
        else
          {:error, :not_found} -> {:ok, opts}
          _ -> {:ok, opts}
        end
    end
  end

  def resolve_interface_options(_), do: {:error, :invalid_schema_options}

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

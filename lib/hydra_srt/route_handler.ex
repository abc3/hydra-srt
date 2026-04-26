defmodule HydraSrt.RouteHandler do
  @moduledoc false

  require Logger
  @behaviour :gen_statem
  @normal_port_exit_reasons [:normal, :epipe]

  alias HydraSrt.Db
  alias HydraSrt.Helpers

  def start_link(args), do: :gen_statem.start_link(__MODULE__, args, [])

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
      shutdown_reason: nil
    }

    {:ok, :start, data, {:next_event, :internal, :start}}
  end

  @impl true
  def handle_event(:internal, :start, _state, data) do
    Logger.info("RouteHandler: starting route #{data.id}")
    port = start_native_pipeline(data.route)
    Logger.info("RouteHandler: Started port: #{inspect(port)}")

    case send_initial_command(port, data.id) do
      :ok ->
        HydraSrt.mark_route_started(data.id)
        {:next_state, :started, %{data | port: port}}

      {:error, reason} ->
        Logger.error("RouteHandler: Failed to start: #{inspect(reason)}")
        kill_stale_pipeline_processes(data.id, "failed_start")
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

  def handle_event(:info, {port, {:exit_status, status}}, _state, %{port: port} = data) do
    log_fun = if status == 0, do: &Logger.info/1, else: &Logger.error/1
    log_fun.("RouteHandler: native pipeline exited with status #{status}")

    if status == 0 do
      {:stop, :normal, %{data | shutdown_reason: {:port_exit, 0}}}
    else
      {:stop, {:port_exit, status}, data}
    end
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

  defp send_initial_command(port, route_id) do
    with {:ok, params} <- route_data_to_params(route_id),
         {:ok, params} <- Jason.encode(params),
         :ok <- command_port(port, params <> "\n") do
      Logger.info("RouteHandler: sent initial command")
      :ok
    else
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
          if Port.command(port, payload), do: :ok, else: {:error, :command_failed}
        rescue
          ArgumentError -> {:error, :closed}
        end
    end
  end

  defp command_port(_port, _payload), do: {:error, :invalid_port}

  defp close_port(port) do
    try do
      if is_nil(Port.info(port)) do
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

        case normalize_runtime_status(status, reason) do
          {:update, normalized_status} ->
            HydraSrt.set_route_runtime_status(data.id, normalized_status)
            data

          :ignore ->
            data
        end

      {:stats, stats} ->
        # Logger.info("RouteHandler: pipeline stats: #{json}")
        publish_stats(data.id, stats)
        data

      :unknown ->
        Logger.warning("RouteHandler: unknown native json line: #{inspect(json)}")
        data
    end
  end

  defp process_port_line(line, data) do
    Logger.warning("RouteHandler: pipeline: #{inspect(line)}")
    data
  end

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
  def publish_stats(route_id, %{} = stats) when is_binary(route_id) do
    stats
    |> stats_events(route_id)
    |> Enum.each(fn event ->
      Phoenix.PubSub.broadcast(HydraSrt.PubSub, "stats", {:stats, event})
    end)

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

  def route_data_to_params(route_id) do
    with {:ok, route} <- Db.get_route(route_id, true),
         {:ok, source} <- source_from_record(route),
         {:ok, sinks} <- sinks_from_record(route) do
      {:ok, %{"source" => source, "sinks" => sinks}}
    end
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
    Logger.warning("RouteHandler: sinks_from_record: no destinations")
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

    localport = Map.get(opts, "localport")

    query_params =
      %{}
      |> maybe_add_param(opts, "mode")
      |> maybe_add_param(opts, "passphrase")
      |> maybe_add_param(opts, "pbkeylen")
      |> maybe_add_param(opts, "poll-timeout")

    # Some clients (notably ffmpeg) reject `srt://:port?...` for listener mode,
    # so we always include the host (usually from `localaddress`).
    host =
      case mode do
        "listener" -> localaddress
        _ -> localaddress
      end

    URI.to_string(%URI{
      scheme: "srt",
      host: host,
      port: localport,
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
    name = Map.get(destination, "name", id)

    # Native pipeline expects SRT properties directly on the element config (not a URI).
    {:ok,
     %{
       "type" => "srtsink",
       "uri" => build_srt_uri(opts),
       "hydra_destination_id" => id,
       "hydra_destination_name" => name,
       "hydra_destination_schema" => "SRT"
     }
     |> Map.merge(opts)}
  end

  def sink_from_record(%{"id" => id, "schema" => "UDP", "schema_options" => opts} = destination) do
    name = Map.get(destination, "name", id)

    # Native pipeline expects `address` and `port` (it maps `address` -> udpsink host property).
    address = Map.get(opts, "address") || Map.get(opts, "host")
    port = Map.get(opts, "port")

    {:ok,
     %{
       "type" => "udpsink",
       "address" => address,
       "host" => address,
       "port" => port,
       "hydra_destination_id" => id,
       "hydra_destination_name" => name,
       "hydra_destination_schema" => "UDP"
     }}
  end

  def sink_from_record(_), do: {:error, :invalid_destination}

  def source_from_record(%{"schema" => "SRT", "schema_options" => opts}) do
    # Native pipeline expects SRT properties directly on the element config (not a URI).
    {:ok, %{"type" => "srtsrc", "uri" => build_srt_uri(opts)} |> Map.merge(opts)}
  end

  def source_from_record(%{"schema" => "UDP", "schema_options" => opts}) do
    # Native pipeline expects `address` and `port` for udpsrc.
    {:ok, %{"type" => "udpsrc"} |> Map.merge(opts)}
  end

  def source_from_record(_), do: {:error, :invalid_source}

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

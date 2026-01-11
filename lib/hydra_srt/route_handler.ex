defmodule HydraSrt.RouteHandler do
  @moduledoc false

  require Logger
  @behaviour :gen_statem

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
      route: route
    }

    {:ok, :start, data, {:next_event, :internal, :start}}
  end

  @impl true
  def handle_event(:internal, :start, _state, data) do
    port = start_native_pipeline(data.route)
    Logger.info("RouteHandler: Started port: #{inspect(port)}")

    case send_initial_command(port, data.id) do
      :ok ->
        HydraSrt.set_route_status(data.id, "started")
        {:next_state, :started, %{data | port: port}}

      {:error, reason} ->
        Logger.error("RouteHandler: Failed to start: #{inspect(reason)}")
        {:stop, reason, data}
    end
  end

  def handle_event(:info, {_port, {:data, info}}, _state, _data) do
    String.split(info, "\n")
    |> Enum.each(fn line ->
      Logger.warning("RouteHandler: pipeline: #{inspect(line)}")
    end)

    :keep_state_and_data
  end

  def handle_event(type, content, state, data) do
    Logger.error(
      "RouteHandler: Undefined msg: #{inspect([{"type", type}, {"content", content}, {"state", state}, {"data", data}],
      pretty: true)}"
    )

    :keep_state_and_data
  end

  @impl true
  def terminate(reason, _state, %{port: port, id: id}) when is_port(port) do
    Logger.info("RouteHandler: reason: #{inspect(reason)} Closing port #{inspect(port)}")
    close_port(port)
    HydraSrt.set_route_status(id, "stopped")
    :ok
  end

  def terminate(reason, _state, data) do
    Logger.info("RouteHandler: reason: #{inspect(reason)}")
    HydraSrt.set_route_status(data.id, "stopped")
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
    if Mix.env() in [:dev, :test] do
      Path.expand("./native/build/hydra_srt_pipeline")
    else
      "#{:code.priv_dir(:hydra_srt)}/native/build/hydra_srt_pipeline"
    end
  end

  defp send_initial_command(port, route_id) do
    with {:ok, params} <- route_data_to_params(route_id),
         {:ok, params} <- Jason.encode(params),
         true <- Port.command(port, params <> "\n") do
      Logger.info("RouteHandler: sent initial command")
      :ok
    else
      error ->
        Logger.error("RouteHandler: send_initial_command failed: #{inspect(error)}")
        {:error, error}
    end
  end

  defp close_port(port) do
    try do
      case Port.info(port, :os_pid) do
        {:os_pid, pid} when is_integer(pid) ->
          Logger.info("RouteHandler: Killing external process with PID #{pid}")
          Helpers.sys_kill(pid)

        _ ->
          Logger.warning("RouteHandler: Could not get OS PID, relying on Port.close/1")
      end

      Port.close(port)
    rescue
      error ->
        Logger.error("RouteHandler: Error closing port: #{inspect(error)}")
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

  @doc false
  def build_srt_uri(opts) when is_map(opts) do
    mode = Map.get(opts, "mode")
    localaddress = Map.get(opts, "localaddress", "127.0.0.1")
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

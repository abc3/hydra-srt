defmodule HydraSrt.ThumbnailWorker do
  @moduledoc false
  use GenServer
  require Logger

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def child_spec(args) do
    %{
      id: {:thumbnail_worker, args.route_id, args.source_id},
      start: {__MODULE__, :start_link, [args]},
      restart: :transient,
      type: :worker
    }
  end

  @impl true
  def init(args) do
    Process.flag(:trap_exit, true)

    case open_and_initialize(args.route_id, args.source_id) do
      {:ok, port} ->
        {:ok, %{route_id: args.route_id, source_id: args.source_id, port: port, port_buffer: ""}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) when is_binary(data) do
    {:noreply, consume_port_output(data, state)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.info(
      "ThumbnailWorker: native thumbnail pipeline exited route_id=#{state.route_id} source_id=#{state.source_id} status=#{status}"
    )

    {:stop, {:port_exit, status}, %{state | port: nil}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.info(
      "ThumbnailWorker: port exit route_id=#{state.route_id} source_id=#{state.source_id} reason=#{inspect(reason)}"
    )

    {:stop, reason, %{state | port: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    close_port(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @spec open_and_initialize(String.t(), String.t()) :: {:ok, port()} | {:error, term()}
  def open_and_initialize(route_id, source_id) do
    with {:ok, route} <- HydraSrt.Db.get_route(route_id, false),
         {:ok, source_record} <- HydraSrt.RouteHandler.source_record_from_route(route, source_id),
         {:ok, source} <- HydraSrt.RouteHandler.source_from_record(source_record),
         {:ok, port} <- open_native_pipeline(route),
         :ok <- send_initial_command(port, %{"source" => source, "sinks" => []}) do
      {:ok, port}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec open_native_pipeline(map()) :: {:ok, port()} | {:error, term()}
  def open_native_pipeline(route) when is_map(route) do
    binary_path = Path.join([:code.priv_dir(:hydra_srt), "native", "hydra_srt_pipeline"])
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

    {:ok, Port.open({:spawn_executable, String.to_charlist(binary_path)}, base_opts ++ env_opts)}
  rescue
    error -> {:error, error}
  end

  @spec send_initial_command(port(), map()) :: :ok | {:error, term()}
  def send_initial_command(port, params) when is_port(port) and is_map(params) do
    with {:ok, json} <- Jason.encode(params) do
      command_port(port, json <> "\n")
    end
  end

  @spec command_port(port(), binary()) :: :ok | {:error, term()}
  def command_port(port, payload) when is_port(port) and is_binary(payload) do
    case Port.info(port) do
      nil ->
        {:error, :closed}

      _info ->
        Port.command(port, payload)
        :ok
    end
  rescue
    ArgumentError -> {:error, :closed}
  end

  @spec close_port(term()) :: :ok
  def close_port(port) when is_port(port) do
    if Port.info(port) do
      Port.close(port)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  def close_port(_port), do: :ok

  @spec consume_port_output(binary(), map()) :: map()
  def consume_port_output(chunk, state) when is_binary(chunk) and is_map(state) do
    [buffer | completed_lines] =
      (state.port_buffer <> chunk)
      |> String.split("\n")
      |> Enum.reverse()

    completed_lines
    |> Enum.reverse()
    |> Enum.reduce(%{state | port_buffer: buffer}, fn line, acc ->
      process_port_line(String.trim_trailing(line, "\r"), acc)
    end)
  end

  @spec process_port_line(binary(), map()) :: map()
  def process_port_line("", state), do: state

  def process_port_line("{" <> _ = json, state) do
    case HydraSrt.RouteHandler.parse_native_json_line(json) do
      {:thumbnail, thumbnail_event} ->
        HydraSrt.RouteHandler.publish_thumbnail(state.route_id, state.source_id, thumbnail_event)

      _ ->
        :ok
    end

    state
  end

  def process_port_line(line, state) do
    Logger.debug(
      "ThumbnailWorker: native output route_id=#{state.route_id} source_id=#{state.source_id}: #{line}"
    )

    state
  end
end

defmodule HydraSrt.UnixSockHandler do
  @moduledoc false

  require Logger

  @behaviour :ranch_protocol
  @behaviour :gen_statem

  alias HydraSrt.Helpers
  alias HydraSrt.Metrics
  alias HydraSrt.Db
  @impl true
  def start_link(ref, transport, opts) do
    Logger.debug(
      "Starting UnixSockHandler with ref: #{inspect(ref)}, transport: #{inspect(transport)}, opts: #{inspect(opts)}"
    )

    pid = :proc_lib.spawn_link(__MODULE__, :init, [ref, transport, opts])
    {:ok, pid}
  end

  @impl true
  def callback_mode, do: [:handle_event_function]

  @impl true
  def init(_), do: :ignore

  def init(ref, trans, _opts) do
    Process.flag(:trap_exit, true)
    Helpers.set_max_heap_size(90)

    {:ok, sock} = :ranch.handshake(ref)

    :ok =
      trans.setopts(sock,
        # mode: :binary,
        # packet: :raw,
        # recbuf: 8192,
        # sndbuf: 8192,
        # # backlog: 2048,
        # send_timeout: 120,
        # keepalive: true,
        # nodelay: true,
        # nopush: true,
        packet: 4,
        active: true
      )

    data = %{
      sock: sock,
      trans: trans,
      source_stream_id: nil,
      route_id: nil,
      route_record: nil
    }

    :gen_statem.enter_loop(__MODULE__, [hibernate_after: 5_000], :exchange, data)
  end

  @impl true
  def handle_event(:info, {:tcp, _port, "route_id:" <> route_id}, _state, data) do
    Logger.info("route_id: #{route_id}")

    route_record =
      case Db.get_route(route_id, true) do
        {:ok, record} ->
          Logger.info("route_record: #{inspect(record, pretty: true)}")
          record

        other ->
          Logger.error("Error getting route record: #{inspect(other)}")
          nil
      end

    {:keep_state, %{data | route_id: route_id, route_record: route_record}}
  end

  def handle_event(
        :info,
        {:tcp, _port, "{" <> _ = json},
        _,
        %{route_record: %{"exportStats" => exportStats?}} = data
      ) do
    case Jason.decode(json) do
      {:ok, stats} ->
        try do
          Phoenix.PubSub.broadcast(
            HydraSrt.PubSub,
            "stats:#{data.route_id}",
            {:stats, stats}
          )

          export = exportStats? and Application.get_env(:hydra_srt, :export_metrics?)
          stats_to_metrics(stats, data, export)
        rescue
          error ->
            Logger.error(
              "Error processing stats: #{inspect(error)} route_id=#{inspect(data.route_id)} source_stream_id=#{inspect(data.source_stream_id)}"
            )
        end

      {error, _} ->
        Logger.error("Error decoding stats: #{inspect(error)} #{inspect(json)}")
    end

    :keep_state_and_data
  end

  def handle_event(:info, {:tcp, _port, "{" <> _}, _, _) do
    # ignore stats
    :keep_state_and_data
  end

  def handle_event(:info, {:tcp, _port, "stats_source_stream_id:" <> stream_id}, _state, data) do
    Logger.info("stats_source_stream_id: #{stream_id}")
    {:keep_state, %{data | source_stream_id: stream_id}}
  end

  def handle_event(:info, {:tcp_closed, _socket}, _state, _data) do
    {:stop, :normal}
  end

  def handle_event(type, content, state, data) do
    msg = [
      {"type", type},
      {"content", content},
      {"state", state},
      {"data", data}
    ]

    Logger.error("SocketHandler: Undefined msg: #{inspect(msg, pretty: true)}")

    :keep_state_and_data
  end

  @impl true
  def terminate(reason, _state, _data) do
    Logger.debug("SocketHandler: socket closed with reason #{inspect(reason)}")
    :ok
  end

  def stats_to_metrics(_, _, false), do: nil

  def stats_to_metrics(stats, data, _) do
    tags = %{
      type: "source",
      route_id: data.route_id,
      route_name: data.route_record["name"],
      source_stream_id: data.source_stream_id
    }

    cond do
      is_list(stats) ->
        # Some keys (like destinations/callers) are lists of maps; recurse per element.
        Enum.each(stats, fn item -> stats_to_metrics(item, data, true) end)

      is_map(stats) ->
        {fields, nested} =
          Enum.reduce(stats, {%{}, []}, fn {key, value}, {fields, nested} ->
            cond do
              is_list(value) ->
                {fields, Enum.reverse(value, nested)}

              is_map(value) ->
                {fields, [value | nested]}

              true ->
                {Map.put(fields, norm_names(key), value), nested}
            end
          end)

        Metrics.event_fields(fields, tags)

        Enum.each(nested, fn item ->
          stats_to_metrics(item, data, true)
        end)

      true ->
        :ok
    end
  end

  def norm_names(name) do
    name
    |> String.replace("-", "_")
    |> String.downcase()
  end

  ## Internal functions
end

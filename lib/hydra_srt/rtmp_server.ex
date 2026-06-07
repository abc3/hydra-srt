defmodule HydraSrt.RtmpServer do
  @moduledoc """
  Ranch protocol GenServer that proxies RTMP publish/play sessions via PubSub.
  """

  @behaviour :ranch_protocol

  use GenServer

  require Logger

  alias HydraSrt.Rtmp.Session

  @impl :ranch_protocol
  @spec start_link(reference(), module(), keyword()) :: {:ok, pid()}
  def start_link(ref, transport, opts) do
    pid = :proc_lib.spawn_link(__MODULE__, :connect, [ref, transport, opts])
    {:ok, pid}
  end

  @spec connect(reference(), module(), keyword()) :: no_return()
  def connect(ref, transport, _opts) do
    Process.flag(:trap_exit, true)

    {:ok, socket} = :ranch.handshake(ref)
    peer = peer_name(socket)

    Logger.info("RtmpServer connection accepted peer=#{inspect(peer)}")

    session = Session.new(socket, transport, peer)

    session =
      with {:ok, session} <- Session.handshake(session),
           {:ok, session, leftover} <- Session.activate(session) do
        :ok = transport.setopts(socket, active: true)
        process_inbound(session, leftover)
      else
        {:error, reason} ->
          Logger.warning(
            "RtmpServer handshake failed peer=#{inspect(peer)} reason=#{inspect(reason)}"
          )

          :ok = transport.close(socket)
          exit(reason)
      end

    :gen_server.enter_loop(__MODULE__, [], session)
  end

  @impl GenServer
  @spec init(term()) :: {:ok, Session.t()}
  def init(session), do: {:ok, session}

  @impl GenServer
  @spec handle_info(term(), Session.t()) :: {:noreply, Session.t()} | {:stop, term(), Session.t()}
  def handle_info({:tcp, socket, data}, %Session{socket: socket} = session) do
    {:noreply, process_inbound(session, data)}
  end

  def handle_info({:msg, type, data, timestamp}, %Session{phase: :playing} = session)
      when type in [8, 9] and is_binary(data) and is_integer(timestamp) do
    case Session.send_media_chunk(session, type, data, timestamp) do
      :ok ->
        {:noreply, session}

      {:error, reason} ->
        Logger.warning(
          "RtmpServer failed to forward media chunk peer=#{inspect(session.peer)} reason=#{inspect(reason)}"
        )

        {:stop, reason, session}
    end
  end

  def handle_info({:tcp_closed, socket}, %Session{socket: socket, peer: peer} = session) do
    Logger.info("RtmpServer connection closed peer=#{inspect(peer)}")
    {:stop, :normal, Session.unsubscribe_path(session)}
  end

  def handle_info({:tcp_error, socket, reason}, %Session{socket: socket, peer: peer} = session) do
    Logger.warning("RtmpServer tcp error peer=#{inspect(peer)} reason=#{inspect(reason)}")
    {:stop, reason, session}
  end

  def handle_info(message, %Session{peer: peer} = session) do
    Logger.warning(
      "RtmpServer unexpected message peer=#{inspect(peer)} message=#{inspect(message)}"
    )

    {:noreply, session}
  end

  @spec process_inbound(Session.t(), binary()) :: Session.t()
  def process_inbound(session, data) do
    phase_before = session.phase
    {session, outbound} = Session.feed(session, data)

    session =
      case Session.send_outbound(session, outbound) do
        :ok ->
          session

        {:error, reason} ->
          Logger.warning(
            "RtmpServer failed to send outbound peer=#{inspect(session.peer)} reason=#{inspect(reason)}"
          )

          session
      end

    if session.phase == :playing && phase_before != :playing do
      :ok = Session.send_cached_bootstrap(session)
    end

    session
  end

  @spec peer_name(:gen_tcp.socket()) :: term()
  def peer_name(socket) do
    case :inet.peername(socket) do
      {:ok, peer} -> peer
      {:error, reason} -> {:error, reason}
    end
  end
end

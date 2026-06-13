defmodule HydraSrt.Rtmp.Session do
  @moduledoc """
  RTMP session state and protocol handling for a single Ranch connection.
  """

  require Logger

  alias ExRTMP.ChunkParser
  alias ExRTMP.Message
  alias ExRTMP.Message.Command.NetConnection
  alias ExRTMP.Message.Command.NetConnection.{CreateStream, Response}
  alias ExRTMP.Message.Command.NetStream.{FCPublish, OnStatus, Play, Publish}
  alias ExRTMP.Message.Metadata
  alias HydraSrt.Rtmp.StreamCache

  @default_acknowledgement_size 3_000_000
  @default_chunk_size 128
  @recv_timeout 10_000

  @type phase :: :handshake | :init | :connected | :publishing | :playing

  @type t :: %__MODULE__{
          socket: :gen_tcp.socket(),
          transport: module(),
          peer: term(),
          chunk_parser: ChunkParser.t(),
          phase: phase(),
          stream_id: non_neg_integer() | nil,
          chunk_size: non_neg_integer(),
          app: String.t() | nil,
          stream_name: String.t() | nil,
          path: String.t() | nil
        }

  defstruct [
    :socket,
    :transport,
    :peer,
    chunk_parser: ChunkParser.new(),
    phase: :handshake,
    stream_id: nil,
    chunk_size: @default_chunk_size,
    app: nil,
    stream_name: nil,
    path: nil
  ]

  @spec new(:gen_tcp.socket(), module(), term()) :: t()
  def new(socket, transport, peer) do
    %__MODULE__{socket: socket, transport: transport, peer: peer}
  end

  @spec handshake(t()) :: {:ok, t()} | {:error, :handshake_failed}
  def handshake(%__MODULE__{} = session) do
    s1_rand = :crypto.strong_rand_bytes(1528)

    result =
      with {:ok, _version} <- transport_recv(session, 1),
           :ok <- transport_send(session, <<3>>),
           :ok <- transport_send(session, <<0::64, s1_rand::binary>>),
           {:ok, <<c::64, client_random::binary-size(1528)>>} <- transport_recv(session, 1536),
           :ok <- transport_send(session, <<c::64, client_random::binary>>),
           {:ok, <<0::32, _::32, ^s1_rand::binary>>} <- transport_recv(session, 1536) do
        :ok
      else
        _ -> :error
      end

    case result do
      :ok ->
        Logger.debug("RtmpServer handshake successful peer=#{inspect(session.peer)}")
        {:ok, %{session | phase: :init}}

      :error ->
        Logger.warning("RtmpServer handshake failed peer=#{inspect(session.peer)}")
        {:error, :handshake_failed}
    end
  end

  @spec configure_socket(t()) :: :ok
  def configure_socket(%__MODULE__{socket: socket}) do
    :inet.setopts(socket,
      send_timeout: 10_000,
      send_timeout_close: true,
      nodelay: true
    )
  end

  @spec activate(t()) :: {:ok, t(), binary()}
  def activate(%__MODULE__{} = session) do
    :ok = configure_socket(session)
    leftover = drain_socket(session)
    {:ok, session, leftover}
  end

  @spec drain_socket(t()) :: binary()
  def drain_socket(%__MODULE__{} = session) do
    case transport_recv(session, 0) do
      {:ok, data} -> data
      {:error, _} -> <<>>
    end
  end

  @spec feed(t(), binary()) :: {t(), [Message.t()]}
  def feed(%__MODULE__{} = session, data) do
    {messages, parser} = ChunkParser.process(data, session.chunk_parser)
    session = %{session | chunk_parser: parser}

    Enum.reduce(messages, {session, []}, fn message, {current_session, outbound} ->
      {updated_session, new_outbound} = dispatch_message(current_session, message)
      {updated_session, outbound ++ new_outbound}
    end)
  end

  @spec dispatch_message(t(), Message.t()) :: {t(), [Message.t()]}
  def dispatch_message(%__MODULE__{} = session, %Message{type: 3, payload: received_bytes}) do
    Logger.debug(
      "RtmpServer window acknowledgement received_bytes=#{received_bytes} peer=#{inspect(session.peer)}"
    )

    {session, []}
  end

  def dispatch_message(%__MODULE__{} = session, %Message{type: 5, payload: win_size}) do
    Logger.debug("RtmpServer window size=#{win_size} peer=#{inspect(session.peer)}")

    {session, []}
  end

  def dispatch_message(%__MODULE__{} = session, %Message{type: 4}) do
    {session, []}
  end

  def dispatch_message(%__MODULE__{phase: :publishing, path: path} = session, %Message{
        type: type,
        payload: payload,
        timestamp: timestamp
      })
      when type in [8, 9] and is_binary(path) and path != "" do
    payload_size = payload_byte_size(payload)
    _ = payload_size
    data = IO.iodata_to_binary(payload)

    :ok = StreamCache.record_media(path, type, data, timestamp)
    :ok = Phoenix.PubSub.broadcast(HydraSrt.PubSub, path, {:msg, type, data, timestamp})

    # Logger.info(
    #   "RtmpServer media chunk path=#{path} type=#{type} bytes=#{payload_size} peer=#{inspect(session.peer)}"
    # )

    {session, []}
  end

  def dispatch_message(%__MODULE__{} = session, %Message{type: type})
      when type in [8, 9] do
    {session, []}
  end

  def dispatch_message(%__MODULE__{path: path} = session, %Message{
        type: 18,
        payload: %Metadata{data: data},
        timestamp: timestamp
      })
      when is_binary(path) and path != "" do
    :ok = StreamCache.record_metadata(path, data, timestamp)

    Logger.debug(
      "RtmpServer metadata path=#{path} peer=#{inspect(session.peer)} data=#{inspect(data)}"
    )

    {session, []}
  end

  def dispatch_message(%__MODULE__{} = session, %Message{type: 18, payload: %Metadata{data: data}}) do
    Logger.debug("RtmpServer metadata peer=#{inspect(session.peer)} data=#{inspect(data)}")
    {session, []}
  end

  def dispatch_message(%__MODULE__{} = session, %Message{type: 20} = message) do
    handle_command_message(session, message)
  end

  def dispatch_message(%__MODULE__{} = session, message) do
    Logger.warning(
      "RtmpServer unhandled message type=#{message.type} peer=#{inspect(session.peer)}"
    )

    {session, []}
  end

  @spec rtmp_command_result(number(), term()) :: Message.t()
  def rtmp_command_result(transaction_id, data) do
    Message.command(Response.ok(trunc(transaction_id), data: data))
  end

  @spec handle_command_message(t(), Message.t()) :: {t(), [Message.t()]}
  def handle_command_message(%__MODULE__{} = session, message) do
    case message.payload do
      %NetConnection.Connect{} ->
        handle_connect_message(session, message.payload)

      %CreateStream{} ->
        handle_create_stream_message(session, message.payload)

      %FCPublish{transaction_id: id, name: name} ->
        session = put_stream_name(session, name)
        {session, [Message.command(Response.ok(id))]}

      %Publish{} ->
        handle_publish_message(session, message.payload, message.stream_id)

      %Play{} ->
        handle_play_message(session, message.payload, message.stream_id)

      ["getStreamLength", transaction_id | _rest]
      when is_number(transaction_id) ->
        {session, [rtmp_command_result(transaction_id, 0)]}

      ["_checkbw", transaction_id | _rest]
      when is_number(transaction_id) ->
        {session, [rtmp_command_result(transaction_id, nil)]}

      [command_name, transaction_id, nil | _rest]
      when is_binary(command_name) and is_number(transaction_id) ->
        Logger.debug("RtmpServer ignore command=#{command_name} peer=#{inspect(session.peer)}")

        {session, [rtmp_command_result(transaction_id, nil)]}

      other ->
        Logger.warning(
          "RtmpServer unknown command peer=#{inspect(session.peer)} payload=#{inspect(other)}"
        )

        {session, []}
    end
  end

  @spec handle_connect_message(t(), NetConnection.Connect.t()) :: {t(), [Message.t()]}
  def handle_connect_message(%__MODULE__{phase: :connected} = session, _connect) do
    {session, [Message.command(Response.connect_failed("Already connected"))]}
  end

  def handle_connect_message(%__MODULE__{} = session, %NetConnection.Connect{
        properties: properties
      }) do
    session =
      session
      |> put_app(Map.get(properties, "app"))
      |> Map.put(:phase, :connected)

    outbound = [
      Message.window_acknowledgment_size(@default_acknowledgement_size),
      Message.command(Response.ok(1))
    ]

    {session, outbound}
  end

  @spec handle_create_stream_message(t(), CreateStream.t()) :: {t(), [Message.t()]}
  def handle_create_stream_message(
        %__MODULE__{phase: :connected, stream_id: nil} = session,
        create_stream
      ) do
    message =
      create_stream.transaction_id
      |> Response.ok(data: 1)
      |> Message.command()

    {%{session | stream_id: 1}, [message]}
  end

  def handle_create_stream_message(%__MODULE__{phase: phase, stream_id: stream_id} = session, %{
        transaction_id: id
      }) do
    reason =
      cond do
        phase != :connected -> "Not Connected"
        stream_id != nil -> "Stream Already Created"
        true -> "Not Connected"
      end

    {session, [Message.command(Response.create_stream_failed(id, reason))]}
  end

  @spec handle_publish_message(t(), Publish.t(), non_neg_integer()) :: {t(), [Message.t()]}
  def handle_publish_message(
        %__MODULE__{phase: :connected, stream_id: stream_id} = session,
        publish,
        _message_stream_id
      )
      when is_integer(stream_id) do
    session =
      session
      |> put_stream_name(publish.name)
      |> Map.put(:phase, :publishing)

    Logger.debug(
      "RtmpServer publish path=#{session.path} stream_id=#{stream_id} peer=#{inspect(session.peer)}"
    )

    outbound = [
      Message.stream_begin(stream_id),
      Message.command(OnStatus.publish_ok(), stream_id)
    ]

    {session, outbound}
  end

  def handle_publish_message(%__MODULE__{} = session, _publish, message_stream_id) do
    {session, [Message.command(OnStatus.publish_bad_stream(), message_stream_id)]}
  end

  @spec handle_play_message(t(), Play.t(), non_neg_integer()) :: {t(), [Message.t()]}
  def handle_play_message(
        %__MODULE__{phase: :connected, stream_id: stream_id} = session,
        play,
        _message_stream_id
      )
      when is_integer(stream_id) do
    session =
      session
      |> put_stream_name(play.name)
      |> Map.put(:phase, :playing)
      |> subscribe_path()

    Logger.debug(
      "RtmpServer play path=#{session.path} stream_id=#{stream_id} peer=#{inspect(session.peer)}"
    )

    outbound = [
      Message.stream_begin(stream_id),
      Message.command(OnStatus.play_ok(), stream_id)
    ]

    {session, outbound}
  end

  def handle_play_message(%__MODULE__{} = session, _play, message_stream_id) do
    {session, [Message.command(OnStatus.play_bad_stream(), message_stream_id)]}
  end

  @spec subscribe_path(t()) :: t()
  def subscribe_path(%__MODULE__{path: path} = session) when is_binary(path) and path != "" do
    :ok = Phoenix.PubSub.subscribe(HydraSrt.PubSub, path)
    session
  end

  def subscribe_path(session), do: session

  @spec unsubscribe_path(t()) :: t()
  def unsubscribe_path(%__MODULE__{path: path, phase: :playing} = session)
      when is_binary(path) and path != "" do
    :ok = Phoenix.PubSub.unsubscribe(HydraSrt.PubSub, path)
    session
  end

  def unsubscribe_path(session), do: session

  @spec send_media_chunk(t(), 8 | 9, binary(), non_neg_integer()) :: :ok | {:error, term()}
  def send_media_chunk(%__MODULE__{stream_id: stream_id} = session, type, data, timestamp)
      when is_integer(stream_id) do
    message =
      Message.new(data,
        type: type,
        stream_id: stream_id,
        timestamp: timestamp
      )

    serialized =
      Message.serialize(message,
        chunk_stream_id: media_chunk_stream_id(type),
        chunk_size: session.chunk_size
      )

    transport_send(session, serialized)
  end

  def send_media_chunk(%__MODULE__{} = _session, _type, _data, _timestamp),
    do: {:error, :no_stream_id}

  @spec send_cached_bootstrap(t()) :: :ok
  def send_cached_bootstrap(%__MODULE__{path: path} = session) when is_binary(path) do
    case StreamCache.get(path) do
      nil ->
        :ok

      cache ->
        case Map.get(cache, :metadata) do
          {metadata, metadata_ts} -> send_metadata_chunk(session, metadata, metadata_ts)
          nil -> :ok
        end

        case Map.get(cache, :audio_header) do
          {audio, audio_ts} -> send_media_chunk(session, 8, audio, audio_ts)
          nil -> :ok
        end

        case Map.get(cache, :video_header) do
          {video, video_ts} -> send_media_chunk(session, 9, video, video_ts)
          nil -> :ok
        end

        :ok
    end
  end

  def send_cached_bootstrap(_session), do: :ok

  @spec send_metadata_chunk(t(), map(), non_neg_integer()) :: :ok | {:error, term()}
  def send_metadata_chunk(%__MODULE__{stream_id: stream_id} = session, metadata, timestamp)
      when is_integer(stream_id) do
    message =
      Message.new(%Metadata{data: metadata},
        type: 18,
        stream_id: stream_id,
        timestamp: timestamp
      )

    serialized =
      Message.serialize(message,
        chunk_stream_id: 4,
        chunk_size: session.chunk_size
      )

    transport_send(session, serialized)
  end

  def send_metadata_chunk(%__MODULE__{} = _session, _metadata, _timestamp),
    do: {:error, :no_stream_id}

  @spec media_chunk_stream_id(8 | 9) :: pos_integer()
  def media_chunk_stream_id(8), do: 4
  def media_chunk_stream_id(9), do: 3

  @spec serialize_outbound([Message.t()]) :: iodata()
  def serialize_outbound(messages) do
    Enum.map(messages, &Message.serialize/1)
  end

  @spec send_outbound(t(), [Message.t()]) :: :ok | {:error, term()}
  def send_outbound(%__MODULE__{} = session, messages) do
    case messages do
      [] ->
        :ok

      _ ->
        transport_send(session, serialize_outbound(messages))
    end
  end

  @spec transport_recv(t(), non_neg_integer()) :: {:ok, binary()} | {:error, term()}
  def transport_recv(%__MODULE__{socket: socket}, length) do
    :gen_tcp.recv(socket, length, @recv_timeout)
  end

  @spec transport_send(t(), iodata()) :: :ok | {:error, term()}
  def transport_send(%__MODULE__{socket: socket, transport: transport}, data) do
    transport.send(socket, data)
  end

  @spec put_app(t(), String.t() | nil) :: t()
  def put_app(%__MODULE__{} = session, app) do
    %{session | app: app, path: stream_path(app, session.stream_name)}
  end

  @spec put_stream_name(t(), String.t() | nil) :: t()
  def put_stream_name(%__MODULE__{} = session, stream_name) do
    %{session | stream_name: stream_name, path: stream_path(session.app, stream_name)}
  end

  @spec stream_path(String.t() | nil, String.t() | nil) :: String.t() | nil
  def stream_path(app, stream_name) when is_binary(app) and is_binary(stream_name) do
    "/#{app}/#{stream_name}"
  end

  def stream_path(_app, _stream_name), do: nil

  @spec payload_byte_size(iodata()) :: non_neg_integer()
  def payload_byte_size(payload) do
    payload
    |> IO.iodata_to_binary()
    |> byte_size()
  end
end

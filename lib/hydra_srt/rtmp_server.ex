defmodule HydraSrt.RtmpServer do
  @moduledoc """
  Ranch protocol GenServer that proxies RTMP publish/play sessions via PubSub.

  Publish side enforces exclusivity and a live-route gate (see
  `HydraSrt.Rtmp.Session`), resets the StreamCache on publish start, watches for
  audio-only / no-codec publishes and publisher inactivity, and on disconnect
  clears cache + registry and broadcasts `{:publish_eos, path}` so play clients
  (the native `rtmpsrc`) close cleanly and the pipeline sees EOS.
  """

  @behaviour :ranch_protocol

  use GenServer

  require Logger

  alias HydraSrt.Rtmp.PublisherRegistry
  alias HydraSrt.Rtmp.Session
  alias HydraSrt.Rtmp.StreamCache
  alias HydraSrt.Stats.EventLogger

  @default_codec_check_ms :timer.seconds(5)
  @default_inactivity_ms :timer.seconds(10)

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
    session = %{session | publisher_pid: self()}

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
  @spec terminate(term(), Session.t()) :: :ok
  # `cleanup_publishing/1` marks the session `:closed` on every orderly stop path
  # (tcp_closed, tcp_error, stop_publishing all run it before returning `{:stop, _}`),
  # so this clause only fires on a true abnormal exit — a crash, a supervisor kill, or
  # a linked EXIT — where the registry auto-releases the path lock on process death
  # but the StreamCache, `{:publish_eos, path}` broadcast, and `publisher_disconnected`
  # event would otherwise be skipped, leaving play-side `rtmpsrc` clients hanging and
  # the route event log unbalanced.
  def terminate(reason, %Session{phase: :publishing, path: path, peer: peer} = session)
      when is_binary(path) and path != "" do
    Logger.info(
      "RtmpServer publisher abnormal exit running cleanup path=#{path} peer=#{inspect(peer)} reason=#{inspect(reason)}"
    )

    _ = cleanup_publishing(session)
    :ok
  end

  def terminate(_reason, %Session{}) do
    :ok
  end

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

    session =
      case session.phase do
        :publishing -> cleanup_publishing(session)
        :playing -> Session.unsubscribe_path(session)
        _ -> session
      end

    {:stop, :normal, session}
  end

  def handle_info({:tcp_error, socket, reason}, %Session{socket: socket, peer: peer} = session) do
    Logger.warning("RtmpServer tcp error peer=#{inspect(peer)} reason=#{inspect(reason)}")

    session =
      case session.phase do
        :publishing -> cleanup_publishing(session)
        :playing -> Session.unsubscribe_path(session)
        _ -> session
      end

    {:stop, reason, session}
  end

  def handle_info({:publish_eos, eos_path}, %Session{phase: :playing} = session) do
    if eos_path == session.path do
      Logger.info(
        "RtmpServer play session closing on publish eos path=#{eos_path} peer=#{inspect(session.peer)}"
      )

      _ = session.transport.close(session.socket)
      {:stop, :normal, Session.unsubscribe_path(session)}
    else
      {:noreply, session}
    end
  end

  def handle_info(:check_codecs, %Session{phase: :publishing, path: path, peer: peer} = session) do
    session = %{session | codec_check_timer_ref: nil}
    entry = StreamCache.get(path) || %{}
    has_audio = Map.has_key?(entry, :audio_header)
    has_video = Map.has_key?(entry, :video_header)

    cond do
      has_audio and has_video ->
        {:noreply, session}

      has_audio ->
        EventLogger.log_publish_audio_only(session.publish_route_id, path)

        Logger.warning(
          "RtmpServer publish audio-only (no video track) path=#{path} peer=#{inspect(peer)}"
        )

        {:noreply, session}

      has_video ->
        EventLogger.log_publish_video_only(session.publish_route_id, path)

        Logger.warning(
          "RtmpServer publish video-only (no audio track) path=#{path} peer=#{inspect(peer)}"
        )

        {:noreply, session}

      true ->
        EventLogger.log_publish_no_codecs(session.publish_route_id, path)

        Logger.warning(
          "RtmpServer publish delivered no codec headers path=#{path} peer=#{inspect(peer)}"
        )

        stop_publishing(:no_codecs, session)
    end
  end

  def handle_info(:check_codecs, %Session{} = session), do: {:noreply, session}

  def handle_info(
        {:publish_inactivity, token},
        %Session{phase: :publishing, path: path, peer: peer, inactivity_token: token} = session
      )
      when is_reference(token) do
    EventLogger.log_publish_inactivity(session.publish_route_id, path)

    Logger.warning("RtmpServer publish inactivity timeout path=#{path} peer=#{inspect(peer)}")

    stop_publishing(:inactivity, session)
  end

  # A stale inactivity message whose token no longer matches the armed timer: media
  # re-armed the timer after this message was already queued, so ignore it instead of
  # stopping a healthy publisher and clearing its path.
  def handle_info({:publish_inactivity, _stale_token}, %Session{} = session) do
    {:noreply, session}
  end

  def handle_info(
        {:item_status, %{item_id: route_id, status: status}},
        %Session{phase: :publishing, publish_route_ids: route_ids} =
          session
      )
      when is_list(route_ids) and is_binary(route_id) and is_binary(status) do
    if route_id not in route_ids do
      # Status for a route this publisher isn't feeding (e.g. a stale subscription left
      # over from before a rollback): ignore it.
      {:noreply, session}
    else
      if HydraSrt.live_route_status?(status) do
        {:noreply, session}
      else
        # One of the routes ingesting this path left the live set. A path can be fed by
        # several live routes at once, so do NOT tear down on a single stop: re-query the
        # live set and only drop the publisher when no matching route is live anymore.
        handle_route_set_change({:route_status, route_id, status}, session)
      end
    end
  end

  # An item-status broadcast while not publishing, or for a route this publisher isn't
  # feeding: ignore it.
  def handle_info({:item_status, _}, %Session{} = session) do
    {:noreply, session}
  end

  # Failover / manual source switch: `Db.set_route_active_source/3` broadcasts
  # `{:item_source, ...}` on the same `"item:<route_id>"` topic as `:item_status`. The
  # new active source may be an RTMP source on a DIFFERENT path, in which case this
  # publisher's path is no longer ingested by the route — yet without a handler the
  # broadcast hit the unexpected-message clause and the publisher stayed connected,
  # holding `PublisherRegistry` exclusivity on the old path and resetting the
  # inactivity timer on every media chunk. Re-query the live set and tear down unless
  # another matching route still ingests the path.
  def handle_info(
        {:item_source, %{item_id: route_id, active_source_id: active_source_id}},
        %Session{phase: :publishing, publish_route_ids: route_ids, path: path, peer: peer} =
          session
      )
      when is_list(route_ids) and is_binary(route_id) do
    if route_id not in route_ids do
      # Source switch on a route this publisher isn't feeding: ignore it.
      {:noreply, session}
    else
      Logger.info(
        "RtmpServer publish source switch route_id=#{route_id} active_source_id=#{inspect(active_source_id)} path=#{path} peer=#{inspect(peer)}"
      )

      handle_route_set_change({:source_switch, route_id}, session)
    end
  end

  def handle_info({:item_source, _}, %Session{} = session) do
    {:noreply, session}
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

          # If we just accepted a publish but could not deliver publish_ok to the client,
          # release the registry lock and clear the cache so the path is not held until the
          # socket finally drops, then close the dead connection.
          if session.phase == :publishing and phase_before != :publishing do
            session = rollback_publish_acceptance(session)
            _ = session.transport.close(session.socket)
            session
          else
            session
          end
      end

    session =
      cond do
        session.phase == :playing && phase_before != :playing ->
          Session.send_cached_bootstrap(session)
          session

        session.phase == :publishing && phase_before != :publishing ->
          # The route-status subscription was already established inside
          # Session.accept_or_reject_publish (before the registry lock), so only the
          # codec-check and inactivity timers remain to arm here.
          session
          |> schedule_codec_check()
          |> arm_inactivity()

        session.phase == :publishing ->
          arm_inactivity(session)

        true ->
          session
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

  @spec unsubscribe_route_status(Session.t()) :: :ok
  defp unsubscribe_route_status(%Session{publish_route_ids: route_ids})
       when is_list(route_ids) do
    Session.unsubscribe_route_status(route_ids)
  end

  defp unsubscribe_route_status(%Session{}), do: :ok

  # Re-evaluate whether the publish path is still ingested by at least one live route,
  # after either a route stop (`:route_status`) or a source switch / failover
  # (`:source_switch`) on a route that was feeding this publisher. `find_live_routes_by_rtmp_path/1`
  # already filters by the route's active source, so a switch to a backup RTMP source on a
  # different path drops this route from the live set. If no matching live route remains,
  # tear the publisher down so the old path's registry lock and cache are released; otherwise
  # keep it and reconcile the route-status subscriptions with the new live set.
  @spec handle_route_set_change(
          {:route_status, String.t(), String.t()} | {:source_switch, String.t()},
          Session.t()
        ) ::
          {:noreply, Session.t()} | {:stop, :normal, Session.t()}
  defp handle_route_set_change(trigger, %Session{path: path, peer: peer} = session)
       when is_binary(path) and path != "" do
    {label, trigger_route_id} =
      case trigger do
        {:route_status, route_id, status} -> {"status=#{status}", route_id}
        {:source_switch, route_id} -> {"source_switch", route_id}
      end

    case HydraSrt.Db.find_live_routes_by_rtmp_path(path) do
      [] ->
        Logger.info(
          "RtmpServer publish stopping; no live route ingests path=#{path} trigger=#{label} trigger_route_id=#{trigger_route_id} peer=#{inspect(peer)}"
        )

        stop_publishing({:route_not_live, label}, session)

      live_matches ->
        new_ids = Enum.map(live_matches, & &1.id)

        Logger.info(
          "RtmpServer publish continuing; #{length(new_ids)} route(s) still ingest path=#{path} trigger=#{label} trigger_route_id=#{trigger_route_id} peer=#{inspect(peer)}"
        )

        session = refresh_route_status_subscriptions(session, new_ids)
        {:noreply, session}
    end
  end

  # Reconcile the set of route-status subscriptions with the current live set for the
  # path: drop subscriptions for routes no longer live, add ones for newly-live routes,
  # and record the new set on the session. Called after a stop broadcast that did not
  # tear down the publisher because other routes still ingest the path. Callers must pass
  # a non-empty `new_ids` (the live-ingesting set after a re-query); an empty list means
  # the publisher should have been stopped instead.
  @spec refresh_route_status_subscriptions(Session.t(), [String.t(), ...]) :: Session.t()
  defp refresh_route_status_subscriptions(
         %Session{publish_route_ids: old_ids} = session,
         new_ids
       )
       when is_list(old_ids) and is_list(new_ids) and new_ids != [] do
    old_set = MapSet.new(old_ids)
    new_set = MapSet.new(new_ids)

    Session.unsubscribe_route_status(MapSet.to_list(MapSet.difference(old_set, new_set)))
    Session.subscribe_route_status(MapSet.to_list(MapSet.difference(new_set, old_set)))

    # Event attribution uses publish_route_id (a single "primary" route). If the
    # primary left the live set but other routes still ingest the path, roll forward
    # to the head of the remaining set so codec/inactivity/disconnect events are not
    # logged against a stopped route.
    new_primary_id =
      if session.publish_route_id in new_ids,
        do: session.publish_route_id,
        else: hd(new_ids)

    %{session | publish_route_ids: new_ids, publish_route_id: new_primary_id}
  end

  @spec schedule_codec_check(Session.t()) :: Session.t()
  defp schedule_codec_check(session) do
    ref = Process.send_after(self(), :check_codecs, codec_check_ms())
    %{session | codec_check_timer_ref: ref}
  end

  @spec arm_inactivity(Session.t()) :: Session.t()
  defp arm_inactivity(session) do
    cancel_timer(session.inactivity_timer_ref)
    # A unique token ties the scheduled message to this specific arm. A timer that
    # already expired may still have its message queued when media re-arms; the handler
    # ignores any message whose token does not match the current one, so a healthy
    # publisher is not stopped by a stale inactivity delivery.
    token = make_ref()
    ref = Process.send_after(self(), {:publish_inactivity, token}, inactivity_ms())
    %{session | inactivity_timer_ref: ref, inactivity_token: token}
  end

  @spec cancel_timers(Session.t()) :: Session.t()
  defp cancel_timers(session) do
    cancel_timer(session.codec_check_timer_ref)
    cancel_timer(session.inactivity_timer_ref)
    %{session | codec_check_timer_ref: nil, inactivity_timer_ref: nil, inactivity_token: nil}
  end

  @spec cancel_timer(reference() | nil) :: non_neg_integer() | false | :ok
  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref) when is_reference(ref), do: Process.cancel_timer(ref)

  @spec cleanup_publishing(Session.t()) :: Session.t()
  defp cleanup_publishing(%Session{path: path, peer: peer} = session)
       when is_binary(path) and path != "" do
    session = cancel_timers(session)
    unsubscribe_route_status(session)
    PublisherRegistry.unregister(path)
    StreamCache.clear(path)
    Phoenix.PubSub.broadcast(HydraSrt.PubSub, path, {:publish_eos, path})
    EventLogger.log_publisher_disconnected(session.publish_route_id, path, peer)
    # Mark the session terminal so a subsequent `terminate/2` (fired by the
    # `{:stop, reason, _}` returns above) does not run this cleanup a second time.
    %{session | phase: :closed}
  end

  defp cleanup_publishing(%Session{} = session) do
    %{cancel_timers(session) | phase: :closed}
  end

  @spec rollback_publish_acceptance(Session.t()) :: Session.t()
  defp rollback_publish_acceptance(
         %Session{path: path, peer: peer, publish_route_id: route_id} =
           session
       )
       when is_binary(path) and path != "" do
    # The route-status subscription was established inside Session.accept_or_reject_publish
    # before the registry lock, so drop it here before clearing publish_route_id.
    unsubscribe_route_status(session)
    PublisherRegistry.unregister(path)
    StreamCache.clear(path)

    # The publish was accepted (so publisher_connected was emitted) but publish_ok never
    # reached the encoder, so emit the compensating publisher_disconnected to keep the
    # route event log balanced instead of leaving a dangling connected event.
    EventLogger.log_publisher_disconnected(route_id, path, peer)

    %{
      session
      | phase: :connected,
        publish_route_id: nil,
        publish_route_ids: nil,
        publish_started_at: nil
    }
  end

  defp rollback_publish_acceptance(%Session{} = session) do
    %{
      session
      | phase: :connected,
        publish_route_id: nil,
        publish_route_ids: nil,
        publish_started_at: nil
    }
  end

  @spec stop_publishing(term(), Session.t()) :: {:stop, :normal, Session.t()}
  defp stop_publishing(_reason, %Session{} = session) do
    session = cleanup_publishing(session)
    _ = session.transport.close(session.socket)
    {:stop, :normal, session}
  end

  @spec codec_check_ms() :: non_neg_integer()
  defp codec_check_ms,
    do: Application.get_env(:hydra_srt, :rtmp_codec_check_ms, @default_codec_check_ms)

  @spec inactivity_ms() :: non_neg_integer()
  defp inactivity_ms,
    do: Application.get_env(:hydra_srt, :rtmp_publish_inactivity_ms, @default_inactivity_ms)
end

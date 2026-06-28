defmodule HydraSrt.RtmpServerRouteStatusTest do
  use HydraSrt.DataCase, async: false

  alias HydraSrt.Db
  alias HydraSrt.Rtmp.PublisherRegistry
  alias HydraSrt.Rtmp.Session
  alias HydraSrt.Rtmp.StreamCache
  alias HydraSrt.RtmpServer
  alias HydraSrt.TestSupport.RtmpFixtures, as: Fix

  import HydraSrt.DbFixtures

  # A transport that accepts all writes so the publish handshake (publish_ok) is
  # delivered successfully and the session transitions to :publishing for real.
  defmodule WorkingTransport do
    @moduledoc false
    import Kernel, except: [send: 2]
    def close(pid) when is_pid(pid), do: Kernel.send(pid, {:transport_closed})
    def setopts(_pid, _opts), do: :ok
    def send(_pid, _data), do: :ok
  end

  # A transport that, on its first write, broadcasts a route stop on a PubSub topic
  # stashed in :persistent_term. This simulates the route stopping during the publish_ok
  # delivery window — after the publisher is admitted but before process_inbound's
  # post-publish branch runs. With the subscription established before the registry lock
  # (inside accept_or_reject_publish) the server receives the broadcast and stops; without
  # it the broadcast is missed and the publisher stays locked.
  defmodule StopOnFirstSendTransport do
    @moduledoc false
    import Kernel, except: [send: 2]

    @stop_key :rtmp_race_stop

    def send(_pid, _data) do
      case :persistent_term.get(@stop_key, nil) do
        {route_id, message, :once} ->
          :persistent_term.erase(@stop_key)
          # Mirror production: update the route's DB status before broadcasting so the
          # publish-gate re-query (run when the broadcast is handled) sees the stop.
          {:ok, _} = HydraSrt.Db.update_route_schema_status(route_id, "stopped")
          :ok = Phoenix.PubSub.broadcast(HydraSrt.PubSub, "item:" <> route_id, message)

        _ ->
          :ok
      end

      :ok
    end

    def close(pid) when is_pid(pid), do: Kernel.send(pid, {:transport_closed})
    def setopts(_pid, _opts), do: :ok
  end

  defp unique_stream, do: "stream-#{System.unique_integer([:positive])}"

  # Mirror production: a route stop updates the DB runtime status BEFORE broadcasting
  # item_status. The publish-gate teardown re-queries the live set, so the DB must
  # reflect the stop by the time the broadcast is handled.
  defp stop_route!(route_id, status \\ "stopped") do
    {:ok, _} = Db.update_route_schema_status(route_id, status)

    :ok =
      Phoenix.PubSub.broadcast(
        HydraSrt.PubSub,
        "item:#{route_id}",
        {:item_status, %{item_id: route_id, status: status}}
      )
  end

  defp live_route_with_rtmp_source(path, name \\ "rtmp-primary") do
    route =
      route_fixture(%{
        "status" => "processing",
        "schema_status" => nil,
        "started_at" => ~U[2025-02-18 14:51:00Z],
        "stopped_at" => ~U[2025-02-18 14:51:00Z]
      })

    {:ok, _source} =
      Db.create_source(route["id"], %{
        "position" => 0,
        "enabled" => true,
        "name" => name,
        "schema" => "RTMP",
        "path" => path
      })

    route["id"]
  end

  defp live_routes_with_rtmp_source(path, names) do
    Enum.map(names, &live_route_with_rtmp_source(path, &1))
  end

  defp cleanup_registry(path) do
    if PublisherRegistry.owner(path) == self() do
      :ok = Registry.unregister(PublisherRegistry.registry(), path)
    end

    :ok = StreamCache.clear(path)
  end

  defp refute_alive(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    refute Process.alive?(pid)
  end

  # Synchronize with the GenServer until process_inbound has completed the
  # :connected -> :publishing transition (which establishes the route-status
  # subscription). publisher_connected is emitted mid-transition, so without this
  # barrier a broadcast sent right after the event can arrive before the server has
  # actually subscribed.
  defp await_publishing_established(pid) do
    case :sys.get_state(pid) do
      %{phase: :publishing} ->
        :ok

      _ ->
        Process.sleep(5)
        await_publishing_established(pid)
    end
  end

  # Drives a real publish through the running GenServer: feeds the serialized Publish
  # command as if it arrived over TCP, so process_inbound runs inside the server process
  # and the route-status subscription is established for the server pid.
  defp start_publishing_server(path, stream, transport \\ WorkingTransport) do
    session =
      Session.new(self(), transport, {{127, 0, 0, 1}, 60_000})
      |> Map.put(:publisher_pid, self())
      |> Map.put(:phase, :connected)
      |> Map.put(:stream_id, 1)
      |> Map.put(:app, "live")
      |> Map.put(:stream_name, stream)
      |> Map.put(:path, path)

    {:ok, pid} = GenServer.start(RtmpServer, session)

    publish_bytes = ExRTMP.Message.serialize(Fix.publish_message(stream, session.stream_id))
    send(pid, {:tcp, self(), publish_bytes})

    {:ok, pid}
  end

  describe "route status change disconnects an admitted publisher" do
    test "stops the publisher when the route broadcasts a non-live status" do
      stream = unique_stream()
      path = "/live/#{stream}"
      route_id = live_route_with_rtmp_source(path)

      Phoenix.PubSub.subscribe(HydraSrt.PubSub, path)
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{route_id}")

      {:ok, pid} = start_publishing_server(path, stream)

      # The publish was admitted; the server registered and subscribed to the route
      # status topic during the :connected -> :publishing transition.
      assert_receive {:event, %{"event_type" => "publisher_connected"}}, 1_000
      await_publishing_established(pid)
      assert PublisherRegistry.active?(path)
      assert PublisherRegistry.owner(path) == pid

      # Simulate the route stopping: the DB status is updated and item_status is
      # broadcast on "item:<route_id>", exactly as HydraSrt does in production.
      stop_route!(route_id)

      assert_receive {:publish_eos, ^path}, 1_000
      assert_receive {:event, %{"event_type" => "publisher_disconnected"}}, 1_000
      assert_receive {:transport_closed}, 1_000
      refute PublisherRegistry.active?(path)
      assert StreamCache.get(path) == nil
      refute_alive(pid)
    end

    test "keeps the publisher alive when the route broadcasts a live status" do
      stream = unique_stream()
      path = "/live/#{stream}"
      route_id = live_route_with_rtmp_source(path)

      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{route_id}")

      {:ok, pid} = start_publishing_server(path, stream)
      assert_receive {:event, %{"event_type" => "publisher_connected"}}, 1_000
      await_publishing_established(pid)

      :ok =
        Phoenix.PubSub.broadcast(
          HydraSrt.PubSub,
          "item:#{route_id}",
          {:item_status, %{item_id: route_id, status: "restarting"}}
        )

      refute_receive {:publish_eos, ^path}, 200
      assert PublisherRegistry.owner(path) == pid

      GenServer.stop(pid, :normal, 1_000)
      cleanup_registry(path)
    end

    test "a stop broadcast during the publish_ok window is not missed" do
      stream = unique_stream()
      path = "/live/#{stream}"
      route_id = live_route_with_rtmp_source(path)

      Phoenix.PubSub.subscribe(HydraSrt.PubSub, path)
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{route_id}")

      # Arm a one-shot route-stop to fire from inside the transport's first write —
      # i.e. during publish_ok delivery, while the publisher is already admitted but
      # process_inbound has not yet returned. The transport updates the DB status and
      # broadcasts, mirroring production.
      :persistent_term.put(
        :rtmp_race_stop,
        {route_id, {:item_status, %{item_id: route_id, status: "stopped"}}, :once}
      )

      {:ok, pid} = start_publishing_server(path, stream, StopOnFirstSendTransport)

      assert_receive {:event, %{"event_type" => "publisher_connected"}}, 1_000

      # The subscription was established before the registry lock, so the stop broadcast
      # sent during publish_ok delivery is received and the publisher is disconnected
      # instead of staying locked until the TCP socket or inactivity timer drops it.
      assert_receive {:publish_eos, ^path}, 2_000
      assert_receive {:event, %{"event_type" => "publisher_disconnected"}}, 1_000
      assert_receive {:transport_closed}, 1_000
      refute PublisherRegistry.active?(path)
      assert StreamCache.get(path) == nil
      refute_alive(pid)
    end

    test "keeps the publisher alive when one of several matching routes stops, drops it when the last one stops" do
      stream = unique_stream()
      path = "/live/#{stream}"
      [route_a, route_b] = live_routes_with_rtmp_source(path, ["rtmp-a", "rtmp-b"])

      Phoenix.PubSub.subscribe(HydraSrt.PubSub, path)
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{route_a}")
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{route_b}")

      {:ok, pid} = start_publishing_server(path, stream)
      assert_receive {:event, %{"event_type" => "publisher_connected"}}, 1_000
      await_publishing_established(pid)
      assert PublisherRegistry.active?(path)
      assert PublisherRegistry.owner(path) == pid

      # Stop ONE of the two matching routes. The other still ingests the path, so the
      # publisher must stay admitted (tearing it down on a single stop was the bug).
      stop_route!(route_a)
      refute_receive {:publish_eos, ^path}, 500
      assert PublisherRegistry.active?(path)
      assert PublisherRegistry.owner(path) == pid
      assert Process.alive?(pid)

      # Stop the remaining matching route: no live route ingests the path anymore, so
      # the publisher is disconnected and the path is released.
      stop_route!(route_b)
      assert_receive {:publish_eos, ^path}, 1_000
      assert_receive {:event, %{"event_type" => "publisher_disconnected"}}, 1_000
      assert_receive {:transport_closed}, 1_000
      refute PublisherRegistry.active?(path)
      assert StreamCache.get(path) == nil
      refute_alive(pid)
    end

    # Mirror production: a failover / manual source switch calls
    # `Db.set_route_active_source/3`, which updates `active_source_id` AND broadcasts
    # `{:item_source, ...}` on `"item:<route_id>"`. The publish-gate re-query filters by
    # the active source, so switching to a backup RTMP source on a different path drops
    # the route from the live set for the old path.
    defp switch_route_source!(route_id, new_source_id, reason) do
      {:ok, _} = Db.set_route_active_source(route_id, new_source_id, reason)
    end

    # A live route with two RTMP sources on different paths, primary set as active so a
    # publish to `primary_path` is admitted by the gate.
    defp live_route_with_two_rtmp_sources(primary_path, backup_path) do
      route_id =
        route_fixture(%{
          "status" => "processing",
          "schema_status" => nil,
          "started_at" => ~U[2025-02-18 14:51:00Z],
          "stopped_at" => ~U[2025-02-18 14:51:00Z]
        })["id"]

      {:ok, primary} =
        Db.create_source(route_id, %{
          "position" => 0,
          "enabled" => true,
          "name" => "rtmp-primary",
          "schema" => "RTMP",
          "path" => primary_path
        })

      {:ok, backup} =
        Db.create_source(route_id, %{
          "position" => 1,
          "enabled" => true,
          "name" => "rtmp-backup",
          "schema" => "RTMP",
          "path" => backup_path
        })

      {:ok, _} = Db.set_route_active_source(route_id, primary["id"], "manual")

      {route_id, primary["id"], backup["id"]}
    end

    test "drops the publisher when failover switches the active source to a different path" do
      stream = unique_stream()
      primary_path = "/live/#{stream}"
      backup_path = "/live/#{stream}-backup"

      {route_id, _primary_id, backup_id} =
        live_route_with_two_rtmp_sources(primary_path, backup_path)

      Phoenix.PubSub.subscribe(HydraSrt.PubSub, primary_path)
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{route_id}")

      {:ok, pid} = start_publishing_server(primary_path, stream)
      assert_receive {:event, %{"event_type" => "publisher_connected"}}, 1_000
      await_publishing_established(pid)
      assert PublisherRegistry.active?(primary_path)
      assert PublisherRegistry.owner(primary_path) == pid

      # Failover to the backup source on a different path. `set_route_active_source/3`
      # broadcasts {:item_source, ...} on "item:<route_id>"; the handler re-queries the
      # live set, which no longer matches primary_path (the active source is now the
      # backup on backup_path), so the publisher on primary_path is disconnected and the
      # registry lock + cache are released instead of lingering until TCP/inactivity.
      switch_route_source!(route_id, backup_id, "failover")

      assert_receive {:publish_eos, ^primary_path}, 1_000
      assert_receive {:event, %{"event_type" => "publisher_disconnected"}}, 1_000
      assert_receive {:transport_closed}, 1_000
      refute PublisherRegistry.active?(primary_path)
      assert StreamCache.get(primary_path) == nil
      refute_alive(pid)
    end

    test "keeps the publisher when failover switches a fed route off the path but another route still ingests it" do
      stream = unique_stream()
      path = "/live/#{stream}"

      {fed_route_id, _fed_primary, fed_backup} =
        live_route_with_two_rtmp_sources(path, "/live/#{stream}-backup")

      # A second, unrelated live route that also ingests `path` so the publisher stays
      # admitted even after the first route fails over to a source on a different path.
      _other_route_id = live_route_with_rtmp_source(path, "rtmp-other")

      Phoenix.PubSub.subscribe(HydraSrt.PubSub, path)
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{fed_route_id}")

      {:ok, pid} = start_publishing_server(path, stream)
      assert_receive {:event, %{"event_type" => "publisher_connected"}}, 1_000
      await_publishing_established(pid)
      assert PublisherRegistry.active?(path)
      assert PublisherRegistry.owner(path) == pid

      # Failover on the fed route switches its active source off `path`. The handler
      # re-queries the live set, finds the other route still ingests `path`, and keeps
      # the publisher alive (refreshing subscriptions to drop the failed-over route).
      switch_route_source!(fed_route_id, fed_backup, "failover")
      refute_receive {:publish_eos, ^path}, 500
      assert PublisherRegistry.active?(path)
      assert PublisherRegistry.owner(path) == pid
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal, 1_000)
      cleanup_registry(path)
    end

    test "ignores :item_source for a route the publisher isn't feeding" do
      stream = unique_stream()
      path = "/live/#{stream}"

      fed_route_id = live_route_with_rtmp_source(path)

      # An unrelated live route on a different path that the publisher is NOT subscribed
      # to. A stray :item_source for it must be ignored (route_id not in
      # publish_route_ids) and leave the publisher intact.
      other_route_id = live_route_with_rtmp_source("/live/#{stream}-unrelated", "rtmp-unrelated")

      Phoenix.PubSub.subscribe(HydraSrt.PubSub, path)
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{fed_route_id}")

      {:ok, pid} = start_publishing_server(path, stream)
      assert_receive {:event, %{"event_type" => "publisher_connected"}}, 1_000
      await_publishing_established(pid)
      assert PublisherRegistry.owner(path) == pid

      send(pid, {:item_source, %{item_id: other_route_id, active_source_id: "irrelevant"}})

      refute_receive {:publish_eos, ^path}, 200
      assert PublisherRegistry.owner(path) == pid
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal, 1_000)
      cleanup_registry(path)
    end
  end
end

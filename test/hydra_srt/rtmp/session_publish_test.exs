defmodule HydraSrt.Rtmp.SessionPublishTest do
  use HydraSrt.DataCase, async: false

  alias HydraSrt.Db
  alias HydraSrt.Rtmp.PublisherRegistry
  alias HydraSrt.Rtmp.Session
  alias HydraSrt.Rtmp.StreamCache
  alias HydraSrt.TestSupport.RtmpFixtures, as: Fix

  import HydraSrt.DbFixtures

  defp unique_stream, do: "stream-#{System.unique_integer([:positive])}"

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

    {route, route["id"]}
  end

  defp stopped_route_with_rtmp_source(path) do
    route =
      route_fixture(%{
        "status" => "stopped",
        "schema_status" => nil,
        "started_at" => ~U[2025-02-18 14:51:00Z],
        "stopped_at" => ~U[2025-02-18 14:51:00Z]
      })

    {:ok, _source} =
      Db.create_source(route["id"], %{
        "position" => 0,
        "enabled" => true,
        "name" => "rtmp-primary",
        "schema" => "RTMP",
        "path" => path
      })

    route
  end

  defp dispatch_publish(session, name) do
    message = Fix.publish_message(name, session.stream_id || 1)
    Session.dispatch_message(session, message)
  end

  defp cleanup_registry(path) do
    if PublisherRegistry.owner(path) == self() do
      :ok = Registry.unregister(PublisherRegistry.registry(), path)
    end

    :ok = StreamCache.clear(path)
  end

  describe "handle_publish_message/3 publish gate" do
    test "accepts publish when a live route owns the path" do
      stream = unique_stream()
      path = "/live/#{stream}"
      {_route, route_id} = live_route_with_rtmp_source(path)

      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{route_id}")

      session = Fix.connected_session(%{app: "live"})
      {updated, outbound} = dispatch_publish(session, stream)

      assert updated.phase == :publishing
      assert updated.publish_route_id == route_id
      assert PublisherRegistry.active?(path)
      assert PublisherRegistry.owner(path) == self()

      assert [_stream_begin, status | _] = outbound
      assert %ExRTMP.Message.Command.NetStream.OnStatus{} = status.payload

      assert_receive {:event, %{"event_type" => "publisher_connected"}}

      cleanup_registry(path)
    end

    test "admits when several live routes share the path and tracks all of them" do
      stream = unique_stream()
      path = "/live/#{stream}"
      {_ra, route_a} = live_route_with_rtmp_source(path, "rtmp-a")
      {_rb, route_b} = live_route_with_rtmp_source(path, "rtmp-b")

      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{route_a}")

      session = Fix.connected_session(%{app: "live"})
      {updated, _outbound} = dispatch_publish(session, stream)

      assert updated.phase == :publishing
      # The primary route id is recorded for event logging...
      assert updated.publish_route_id == route_a
      # ...and every matching live route is tracked so a stop of one does not tear down
      # the publisher while another still ingests the path.
      assert Enum.sort(updated.publish_route_ids) == Enum.sort([route_a, route_b])
      assert PublisherRegistry.active?(path)

      assert_receive {:event, %{"event_type" => "publisher_connected"}}

      cleanup_registry(path)
    end

    test "clears the StreamCache on publish start" do
      stream = unique_stream()
      path = "/live/#{stream}"
      live_route_with_rtmp_source(path)

      :ok = StreamCache.record_metadata(path, %{"width" => 1280}, 1)
      assert StreamCache.get(path) != nil

      session = Fix.connected_session(%{app: "live"})
      {updated, _outbound} = dispatch_publish(session, stream)

      assert updated.phase == :publishing
      assert StreamCache.get(path) == nil

      cleanup_registry(path)
    end

    test "rejects publish when the owning route is not live" do
      stream = unique_stream()
      path = "/live/#{stream}"
      stopped_route_with_rtmp_source(path)

      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:all")

      session = Fix.connected_session(%{app: "live"})
      {updated, outbound} = dispatch_publish(session, stream)

      assert updated.phase == :connected
      refute PublisherRegistry.active?(path)

      assert [status] = outbound

      assert %ExRTMP.Message.Command.NetStream.OnStatus{info: %{"level" => :error}} =
               status.payload

      assert_receive {:event, %{"event_type" => "publish_rejected", "reason" => "route_not_live"}}

      cleanup_registry(path)
    end

    test "rejects publish when no route matches the path" do
      stream = unique_stream()
      path = "/live/#{stream}"

      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:all")

      session = Fix.connected_session(%{app: "live"})
      {updated, outbound} = dispatch_publish(session, stream)

      assert updated.phase == :connected
      refute PublisherRegistry.active?(path)
      assert [status] = outbound

      assert %ExRTMP.Message.Command.NetStream.OnStatus{info: %{"level" => :error}} =
               status.payload

      assert_receive {:event, %{"event_type" => "publish_rejected"}}

      cleanup_registry(path)
    end

    test "rejects a second concurrent publisher with a conflict" do
      stream = unique_stream()
      path = "/live/#{stream}"
      {_route, route_id} = live_route_with_rtmp_source(path)

      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{route_id}")

      owner_path = path
      parent = self()

      owner_pid =
        spawn(fn ->
          :ok = PublisherRegistry.register(owner_path, self())
          send(parent, :registered)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :registered
      assert PublisherRegistry.owner(path) == owner_pid

      session = Fix.connected_session(%{app: "live"})
      {updated, outbound} = dispatch_publish(session, stream)

      assert updated.phase == :connected
      assert PublisherRegistry.owner(path) == owner_pid

      assert [status] = outbound

      assert %ExRTMP.Message.Command.NetStream.OnStatus{info: %{"level" => :error}} =
               status.payload

      assert_receive {:event, %{"event_type" => "publish_conflict"}}

      send(owner_pid, :stop)
      cleanup_registry(path)
    end
  end

  describe "media dispatch caps-change detection" do
    test "emits publish_caps_changed when the video sequence header changes" do
      stream = unique_stream()
      path = "/live/#{stream}"
      {_route, route_id} = live_route_with_rtmp_source(path)

      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{route_id}")

      session =
        Fix.connected_session(%{
          app: "live",
          phase: :publishing,
          path: path,
          publish_route_id: route_id
        })

      :new = StreamCache.record_media(path, 9, Fix.avc_sequence_header(), 1)

      changed_header = <<0x17, 0x00, 0x00, 0x00, 0x01, 0x77, 0x00, 0x28>>
      message = media_message(9, changed_header, 2, session.stream_id)
      {session, []} = Session.dispatch_message(session, message)

      assert session.phase == :publishing

      assert_receive {:event, %{"event_type" => "publish_caps_changed"}}

      cleanup_registry(path)
    end
  end

  describe "metadata dispatch" do
    test "records metadata in :publishing phase" do
      stream = unique_stream()
      path = "/live/#{stream}"
      {_route, route_id} = live_route_with_rtmp_source(path)

      session =
        Fix.connected_session(%{
          app: "live",
          phase: :publishing,
          path: path,
          publish_route_id: route_id
        })

      message = Fix.metadata_message(%{"width" => 1280}, session.stream_id)
      {session, []} = Session.dispatch_message(session, message)

      assert session.phase == :publishing
      assert %{metadata: {%{"width" => 1280}, 0}} = StreamCache.get(path)

      cleanup_registry(path)
    end

    test "does not cache metadata while still :connected (rejected publish leaves no stale cache)" do
      stream = unique_stream()
      path = "/live/#{stream}"
      stopped_route_with_rtmp_source(path)

      # A misbehaving encoder sends onMetaData before the publish command is accepted;
      # the session is still :connected and the route is not live. The metadata must not
      # be written to the StreamCache, otherwise a later play on the same path would
      # receive bootstrap data from a publisher that was never admitted.
      session = Fix.connected_session(%{app: "live", stream_name: stream, path: path})

      message = Fix.metadata_message(%{"width" => 1920}, session.stream_id)
      {^session, []} = Session.dispatch_message(session, message)

      assert StreamCache.get(path) == nil

      cleanup_registry(path)
    end
  end

  defp media_message(type, data, timestamp, stream_id) do
    ExRTMP.Message.new(data, type: type, timestamp: timestamp, stream_id: stream_id)
  end
end

defmodule HydraSrt.RtmpServerPublishRollbackTest do
  use HydraSrt.DataCase, async: false

  alias HydraSrt.Db
  alias HydraSrt.Rtmp.PublisherRegistry
  alias HydraSrt.Rtmp.StreamCache
  alias HydraSrt.RtmpServer
  alias HydraSrt.TestSupport.RtmpFixtures, as: Fix

  import HydraSrt.DbFixtures

  # A transport whose `send/2` always fails. Used to simulate a dead socket at the
  # moment the server tries to deliver `publish_ok` to a freshly accepted publisher.
  defmodule FailingTransport do
    @moduledoc false
    import Kernel, except: [send: 2]
    def close(pid) when is_pid(pid), do: Kernel.send(pid, {:transport_closed})
    def setopts(_pid, _opts), do: :ok
    def send(_pid, _data), do: {:error, :closed}
  end

  defp unique_stream, do: "stream-#{System.unique_integer([:positive])}"

  defp live_route_with_rtmp_source(path) do
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
        "name" => "rtmp-primary",
        "schema" => "RTMP",
        "path" => path
      })

    route["id"]
  end

  defp cleanup_registry(path) do
    if PublisherRegistry.owner(path) == self() do
      :ok = Registry.unregister(PublisherRegistry.registry(), path)
    end

    :ok = StreamCache.clear(path)
  end

  describe "process_inbound/2 publish-acceptance rollback" do
    test "releases the registry lock and clears the cache when publish_ok cannot be sent" do
      stream = unique_stream()
      path = "/live/#{stream}"
      route_id = live_route_with_rtmp_source(path)

      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{route_id}")

      session =
        Fix.connected_session(%{
          app: "live",
          stream_name: stream,
          path: path,
          socket: self(),
          transport: FailingTransport,
          publisher_pid: self()
        })

      publish_bytes = ExRTMP.Message.serialize(Fix.publish_message(stream, session.stream_id))

      updated = RtmpServer.process_inbound(session, publish_bytes)

      # The publish was accepted (registry locked + cache cleared) then rolled back
      # because publish_ok could not be delivered, so the path must not stay locked.
      refute PublisherRegistry.active?(path)
      assert StreamCache.get(path) == nil
      assert updated.phase == :connected
      assert updated.publish_route_id == nil

      # publisher_connected was emitted on acceptance; the socket is then closed.
      assert_receive {:event, %{"event_type" => "publisher_connected"}}, 1_000

      # The rollback emits a compensating publisher_disconnected so the route event log
      # stays balanced (no dangling connected event with no active publisher).
      assert_receive {:event, %{"event_type" => "publisher_disconnected"}}, 1_000

      assert_receive {:transport_closed}, 1_000

      cleanup_registry(path)
    end
  end
end

defmodule HydraSrt.RtmpServerTest do
  use ExUnit.Case, async: false

  alias HydraSrt.Rtmp.Session
  alias HydraSrt.Rtmp.StreamCache
  alias HydraSrt.TestSupport.RtmpFixtures, as: Fix

  defmodule FakeTransport do
    @moduledoc false
    def close(pid) when is_pid(pid), do: send(pid, {:transport_closed})
    def setopts(_pid, _opts), do: :ok
  end

  defp unique_path, do: "/live/rtmp-server-#{System.unique_integer([:positive])}"

  defp start_server(attrs) do
    defaults = %{
      socket: self(),
      transport: FakeTransport,
      peer: {{127, 0, 0, 1}, 60_000},
      publisher_pid: self()
    }

    session = struct(Session, Map.merge(defaults, attrs))

    {:ok, pid} = GenServer.start(HydraSrt.RtmpServer, session)
    {pid, session}
  end

  defp refute_alive(pid) do
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    refute Process.alive?(pid)
  end

  defp assert_alive(pid) do
    ref = Process.monitor(pid)
    refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200
    Process.demonitor(ref, [:flush])
    assert Process.alive?(pid)
  end

  setup do
    path = unique_path()
    on_exit(fn -> :ok = StreamCache.clear(path) end)
    {:ok, path: path}
  end

  describe "publisher tcp_closed cleanup" do
    test "publishing session broadcasts publish_eos, clears cache, and stops", %{path: path} do
      route_id = "route-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, path)
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{route_id}")

      :ok = StreamCache.record_metadata(path, %{"width" => 1280}, 1)
      assert StreamCache.get(path) != nil

      {pid, session} =
        start_server(%{
          phase: :publishing,
          path: path,
          publish_route_id: route_id,
          stream_id: 1
        })

      send(pid, {:tcp_closed, session.socket})

      assert_receive {:publish_eos, ^path}, 1_000
      assert_receive {:event, %{"event_type" => "publisher_disconnected"}}, 1_000
      assert StreamCache.get(path) == nil

      refute_alive(pid)
    end
  end

  describe "publisher tcp_error cleanup" do
    test "publishing session cleans up like tcp_closed and stops", %{path: path} do
      route_id = "route-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, path)
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{route_id}")

      :ok = StreamCache.record_metadata(path, %{"width" => 1280}, 1)
      assert StreamCache.get(path) != nil

      {pid, session} =
        start_server(%{
          phase: :publishing,
          path: path,
          publish_route_id: route_id,
          stream_id: 1
        })

      send(pid, {:tcp_error, session.socket, :etimedout})

      assert_receive {:publish_eos, ^path}, 1_000
      assert_receive {:event, %{"event_type" => "publisher_disconnected"}}, 1_000
      assert StreamCache.get(path) == nil

      refute_alive(pid)
    end

    test "playing session unsubscribes and stops on tcp_error", %{path: path} do
      {pid, session} = start_server(%{phase: :playing, path: path, stream_id: 1})

      send(pid, {:tcp_error, session.socket, :econnreset})

      refute_alive(pid)
    end
  end

  describe "play-side publish_eos" do
    test "closes the play socket so rtmpsrc sees EOF", %{path: path} do
      {pid, session} = start_server(%{phase: :playing, path: path, stream_id: 1})

      send(pid, {:publish_eos, path})

      assert_receive {:transport_closed}, 1_000
      refute_alive(pid)

      _ = session
    end

    test "ignores publish_eos for a different path", %{path: path} do
      {pid, _session} = start_server(%{phase: :playing, path: path, stream_id: 1})

      send(pid, {:publish_eos, "/live/other"})

      assert_alive(pid)

      GenServer.stop(pid, :normal, 1_000)
    end
  end

  describe "codec-check timer" do
    test "emits publish_audio_only when only an audio header arrived", %{path: path} do
      route_id = "route-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{route_id}")

      :new = StreamCache.record_media(path, 8, Fix.aac_sequence_header(), 1)

      {pid, _session} =
        start_server(%{
          phase: :publishing,
          path: path,
          publish_route_id: route_id,
          stream_id: 1
        })

      send(pid, :check_codecs)

      assert_receive {:event, %{"event_type" => "publish_audio_only"}}, 1_000
      assert_alive(pid)

      GenServer.stop(pid, :normal, 1_000)
    end

    test "emits publish_video_only and stays alive when only a video header arrived", %{
      path: path
    } do
      route_id = "route-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{route_id}")

      :new = StreamCache.record_media(path, 9, Fix.avc_sequence_header(), 1)

      {pid, _session} =
        start_server(%{
          phase: :publishing,
          path: path,
          publish_route_id: route_id,
          stream_id: 1
        })

      send(pid, :check_codecs)

      assert_receive {:event, %{"event_type" => "publish_video_only"}}, 1_000
      refute_receive {:event, %{"event_type" => "publish_no_codecs"}}, 200
      assert_alive(pid)

      GenServer.stop(pid, :normal, 1_000)
    end

    test "closes the session when no codec headers arrived", %{path: path} do
      route_id = "route-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{route_id}")
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, path)

      {pid, _session} =
        start_server(%{
          phase: :publishing,
          path: path,
          publish_route_id: route_id,
          stream_id: 1
        })

      send(pid, :check_codecs)

      assert_receive {:event, %{"event_type" => "publish_no_codecs"}}, 1_000
      assert_receive {:publish_eos, ^path}, 1_000
      assert_receive {:transport_closed}, 1_000
      refute_alive(pid)
    end

    test "stays quiet when both audio and video headers arrived", %{path: path} do
      route_id = "route-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{route_id}")

      :new = StreamCache.record_media(path, 8, Fix.aac_sequence_header(), 1)
      :new = StreamCache.record_media(path, 9, Fix.avc_sequence_header(), 2)

      {pid, _session} =
        start_server(%{
          phase: :publishing,
          path: path,
          publish_route_id: route_id,
          stream_id: 1
        })

      send(pid, :check_codecs)

      refute_receive {:event, %{"event_type" => "publish_audio_only"}}, 200
      assert_alive(pid)

      GenServer.stop(pid, :normal, 1_000)
    end
  end

  describe "inactivity timeout" do
    test "closes the publishing session and broadcasts publish_eos", %{path: path} do
      route_id = "route-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{route_id}")
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, path)

      token = make_ref()

      {pid, _server} =
        start_server(%{
          phase: :publishing,
          path: path,
          publish_route_id: route_id,
          stream_id: 1,
          inactivity_token: token
        })

      send(pid, {:publish_inactivity, token})

      assert_receive {:event, %{"event_type" => "publish_inactivity"}}, 1_000
      assert_receive {:publish_eos, ^path}, 1_000
      assert_receive {:transport_closed}, 1_000
      refute_alive(pid)
    end

    test "ignores a stale inactivity message and keeps the publisher alive", %{path: path} do
      route_id = "route-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{route_id}")

      current_token = make_ref()
      stale_token = make_ref()

      {pid, _server} =
        start_server(%{
          phase: :publishing,
          path: path,
          publish_route_id: route_id,
          stream_id: 1,
          inactivity_token: current_token
        })

      # A stale message (from a timer that fired before media re-armed) must not stop a
      # healthy publisher or clear its path.
      send(pid, {:publish_inactivity, stale_token})

      refute_receive {:event, %{"event_type" => "publish_inactivity"}}, 200
      assert_alive(pid)

      GenServer.stop(pid, :normal, 1_000)
    end
  end

  describe "route status change" do
    test "keeps the publisher alive when the route transitions to another live status", %{
      path: path
    } do
      route_id = "route-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{route_id}")

      {pid, _server} =
        start_server(%{
          phase: :publishing,
          path: path,
          publish_route_id: route_id,
          publish_route_ids: [route_id],
          stream_id: 1
        })

      # restarting is still a live status, so the publisher must not be dropped.
      send(pid, {:item_status, %{item_id: route_id, status: "restarting"}})

      refute_receive {:publish_eos, ^path}, 200
      assert_alive(pid)

      GenServer.stop(pid, :normal, 1_000)
    end

    test "ignores item_status for a route this publisher is not feeding", %{path: path} do
      route_id = "route-#{System.unique_integer([:positive])}"

      {pid, _server} =
        start_server(%{
          phase: :publishing,
          path: path,
          publish_route_id: route_id,
          publish_route_ids: [route_id],
          stream_id: 1
        })

      send(pid, {:item_status, %{item_id: "route-other", status: "stopped"}})

      assert_alive(pid)

      GenServer.stop(pid, :normal, 1_000)
    end
  end

  describe "abnormal exit cleanup" do
    test "terminate/2 runs cleanup_publishing on an abnormal publishing exit", %{path: path} do
      route_id = "route-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, path)
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{route_id}")

      :ok = StreamCache.record_metadata(path, %{"width" => 1280}, 1)
      assert StreamCache.get(path) != nil

      {pid, _session} =
        start_server(%{
          phase: :publishing,
          path: path,
          publish_route_id: route_id,
          stream_id: 1
        })

      # An abnormal stop reason (not :normal/:shutdown) drives GenServer through
      # terminate/2. Without the terminate clause the cache, publish_eos broadcast,
      # and publisher_disconnected event would all be skipped on a real crash.
      GenServer.stop(pid, :boom)

      assert_receive {:publish_eos, ^path}, 1_000
      assert_receive {:event, %{"event_type" => "publisher_disconnected"}}, 1_000
      assert StreamCache.get(path) == nil
    end

    test "orderly stop does not double-run cleanup after cleanup_publishing", %{path: path} do
      route_id = "route-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, path)
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:#{route_id}")

      {pid, session} =
        start_server(%{
          phase: :publishing,
          path: path,
          publish_route_id: route_id,
          stream_id: 1
        })

      # Drive the orderly tcp_closed path, which runs cleanup_publishing and marks the
      # session :closed before returning {:stop, :normal}. GenServer still calls
      # terminate(:normal, ...) afterwards, so it must not re-broadcast or re-emit.
      send(pid, {:tcp_closed, session.socket})

      assert_receive {:publish_eos, ^path}, 1_000
      assert_receive {:event, %{"event_type" => "publisher_disconnected"}}, 1_000
      refute_receive {:publish_eos, ^path}, 200
      refute_receive {:event, %{"event_type" => "publisher_disconnected"}}, 200
      assert StreamCache.get(path) == nil

      refute_alive(pid)
    end
  end
end

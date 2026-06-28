defmodule HydraSrt.DbRtmpPathLookupTest do
  use HydraSrt.DataCase, async: false

  alias HydraSrt.Db

  import HydraSrt.DbFixtures

  defp rtmp_source_fixture(route, attrs) do
    attrs =
      attrs
      |> Enum.into(%{
        "position" => 0,
        "enabled" => true,
        "name" => "rtmp-primary",
        "schema" => "RTMP",
        "path" => "/live/prochid"
      })

    {:ok, source} = Db.create_source(route["id"], attrs)
    source
  end

  defp route_with_status(status) do
    route_fixture(%{
      "status" => status,
      "schema_status" => nil,
      "started_at" => ~U[2025-02-18 14:51:00Z],
      "stopped_at" => ~U[2025-02-18 14:51:00Z]
    })
  end

  describe "find_live_routes_by_rtmp_path/1" do
    test "returns a live route whose RTMP source path matches" do
      route = route_with_status("processing")
      rtmp_source_fixture(route, %{"path" => "/live/prochid"})
      route_id = route["id"]

      assert [%{id: ^route_id, status: "processing"}] =
               Db.find_live_routes_by_rtmp_path("/live/prochid")
    end

    test "excludes routes whose runtime status is not live" do
      route = route_with_status("stopped")
      rtmp_source_fixture(route, %{"path" => "/live/prochid"})

      assert [] = Db.find_live_routes_by_rtmp_path("/live/prochid")
    end

    test "treats all live statuses as live" do
      for status <- ["started", "processing", "starting", "restarting", "reconnecting"] do
        route = route_with_status(status)
        rtmp_source_fixture(route, %{"path" => "/live/#{status}"})

        assert [%{status: ^status}] = Db.find_live_routes_by_rtmp_path("/live/#{status}")
      end
    end

    test "normalizes a path without a leading slash before matching" do
      route = route_with_status("processing")
      rtmp_source_fixture(route, %{"path" => "/live/prochid"})
      route_id = route["id"]

      assert [%{id: ^route_id}] = Db.find_live_routes_by_rtmp_path("live/prochid")
    end

    test "prefers schema_status over status for the live check" do
      route =
        route_fixture(%{
          "status" => "stopped",
          "schema_status" => "processing",
          "started_at" => ~U[2025-02-18 14:51:00Z],
          "stopped_at" => ~U[2025-02-18 14:51:00Z]
        })

      rtmp_source_fixture(route, %{"path" => "/live/override"})
      route_id = route["id"]

      assert [%{id: ^route_id, status: "processing"}] =
               Db.find_live_routes_by_rtmp_path("/live/override")
    end

    test "matches an RTMP destination whose location path points to the local RtmpServer" do
      route = route_with_status("processing")
      route_id = route["id"]

      {:ok, _dest} =
        Db.create_destination(route["id"], %{
          "position" => 0,
          "enabled" => true,
          "name" => "rtmp-out",
          "schema" => "RTMP",
          "location" => "rtmp://127.0.0.1:1935/live/prochid"
        })

      assert [%{id: ^route_id, status: "processing"}] =
               Db.find_live_routes_by_rtmp_path("/live/prochid")
    end

    test "ignores an RTMP destination whose location path does not match" do
      route = route_with_status("processing")

      {:ok, _dest} =
        Db.create_destination(route["id"], %{
          "position" => 0,
          "enabled" => true,
          "name" => "rtmp-out",
          "schema" => "RTMP",
          "location" => "rtmp://youtube.example/live/otherkey"
        })

      assert [] = Db.find_live_routes_by_rtmp_path("/live/prochid")
    end

    test "ignores an external RTMP destination that shares the path suffix" do
      route = route_with_status("processing")

      {:ok, _dest} =
        Db.create_destination(route["id"], %{
          "position" => 0,
          "enabled" => true,
          "name" => "rtmp-out",
          "schema" => "RTMP",
          # Same path suffix, but host is external (e.g. YouTube) — must not open the
          # local publish gate.
          "location" => "rtmp://youtube.example/live/prochid"
        })

      assert [] = Db.find_live_routes_by_rtmp_path("/live/prochid")
    end

    test "ignores a local-host RTMP destination whose port is not the local RtmpServer port" do
      route = route_with_status("processing")

      {:ok, _dest} =
        Db.create_destination(route["id"], %{
          "position" => 0,
          "enabled" => true,
          "name" => "rtmp-out",
          "schema" => "RTMP",
          "location" => "rtmp://127.0.0.1:9999/live/prochid"
        })

      assert [] = Db.find_live_routes_by_rtmp_path("/live/prochid")
    end

    test "dedupes a route that has both an RTMP source and a matching destination" do
      route = route_with_status("processing")
      route_id = route["id"]

      rtmp_source_fixture(route, %{"path" => "/live/prochid"})

      {:ok, _dest} =
        Db.create_destination(route["id"], %{
          "position" => 0,
          "enabled" => true,
          "name" => "rtmp-out",
          "schema" => "RTMP",
          "location" => "rtmp://127.0.0.1:1935/live/prochid"
        })

      assert [%{id: ^route_id, status: "processing"}] =
               Db.find_live_routes_by_rtmp_path("/live/prochid")
    end

    test "returns empty list for an unknown path" do
      assert [] = Db.find_live_routes_by_rtmp_path("/live/nope")
    end

    test "excludes a live route whose route.enabled is false" do
      route =
        route_fixture(%{
          "status" => "processing",
          "schema_status" => nil,
          "enabled" => false,
          "started_at" => ~U[2025-02-18 14:51:00Z],
          "stopped_at" => ~U[2025-02-18 14:51:00Z]
        })

      rtmp_source_fixture(route, %{"path" => "/live/disabled-route"})

      assert [] = Db.find_live_routes_by_rtmp_path("/live/disabled-route")
    end

    test "excludes a live route whose RTMP source endpoint is disabled" do
      route = route_with_status("processing")
      rtmp_source_fixture(route, %{"path" => "/live/prochid", "enabled" => false})

      assert [] = Db.find_live_routes_by_rtmp_path("/live/prochid")
    end

    test "excludes a live route whose RTMP destination endpoint is disabled" do
      route = route_with_status("processing")

      {:ok, _dest} =
        Db.create_destination(route["id"], %{
          "position" => 0,
          "enabled" => false,
          "name" => "rtmp-out",
          "schema" => "RTMP",
          "location" => "rtmp://127.0.0.1:1935/live/prochid"
        })

      assert [] = Db.find_live_routes_by_rtmp_path("/live/prochid")
    end

    test "matches a source that is the route's active_source" do
      route = route_with_status("processing")
      route_id = route["id"]
      source = rtmp_source_fixture(route, %{"path" => "/live/prochid"})

      {:ok, _updated} = Db.update_route(route_id, %{"active_source_id" => source["id"]})

      assert [%{id: ^route_id, status: "processing"}] =
               Db.find_live_routes_by_rtmp_path("/live/prochid")
    end

    test "ignores a source that is not the route's active_source (cold-standby backup)" do
      route = route_with_status("processing")
      route_id = route["id"]

      primary = rtmp_source_fixture(route, %{"path" => "/live/primary", "position" => 0})
      _backup = rtmp_source_fixture(route, %{"path" => "/live/backup", "position" => 1})

      # Pin the active source to the primary; a publish to the backup path must be rejected
      # even though the route is live, because that source is cold-standby.
      {:ok, _updated} = Db.update_route(route_id, %{"active_source_id" => primary["id"]})

      assert [] = Db.find_live_routes_by_rtmp_path("/live/backup")
      assert [%{id: ^route_id}] = Db.find_live_routes_by_rtmp_path("/live/primary")
    end
  end
end

defmodule HydraSrt.ThumbnailManagerTest do
  use ExUnit.Case

  alias HydraSrt.ThumbnailManager

  test "desired_workers includes always thumbnail sources for stopped routes" do
    routes = [
      %{
        "id" => "route-1",
        "status" => "stopped",
        "active_source_id" => "source-1",
        "sources" => [
          %{
            "id" => "source-1",
            "enabled" => true,
            "thumbnail_enabled" => true,
            "thumbnail_capture_policy" => "always"
          }
        ]
      }
    ]

    assert ThumbnailManager.desired_workers(routes) == MapSet.new([{"route-1", "source-1"}])
  end

  test "desired_workers excludes active source owned by running route pipeline" do
    routes = [
      %{
        "id" => "route-1",
        "schema_status" => "processing",
        "active_source_id" => "source-1",
        "sources" => [
          %{
            "id" => "source-1",
            "enabled" => true,
            "thumbnail_enabled" => true,
            "thumbnail_capture_policy" => "always"
          },
          %{
            "id" => "source-2",
            "enabled" => true,
            "thumbnail_enabled" => true,
            "thumbnail_capture_policy" => "always"
          }
        ]
      }
    ]

    assert ThumbnailManager.desired_workers(routes) == MapSet.new([{"route-1", "source-2"}])
  end

  test "desired_workers ignores running policy and disabled sources" do
    routes = [
      %{
        "id" => "route-1",
        "status" => "stopped",
        "sources" => [
          %{
            "id" => "source-1",
            "enabled" => true,
            "thumbnail_enabled" => true,
            "thumbnail_capture_policy" => "running"
          },
          %{
            "id" => "source-2",
            "enabled" => false,
            "thumbnail_enabled" => true,
            "thumbnail_capture_policy" => "always"
          }
        ]
      }
    ]

    assert ThumbnailManager.desired_workers(routes) == MapSet.new()
  end
end

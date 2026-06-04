defmodule HydraSrt.E2E.SourceThumbnailE2ETest do
  use ExUnit.Case, async: false

  alias HydraSrt.TestSupport.E2EHelpers

  @moduletag :e2e

  setup_all do
    E2EHelpers.ensure_e2e_prereqs!()
    {:ok, base_url: E2EHelpers.base_url()}
  end

  test "running route captures a source thumbnail JPEG", %{base_url: base_url} do
    token = E2EHelpers.api_login!(base_url, "admin", "password123")

    source_port = E2EHelpers.tcp_free_port!()
    sink_port = E2EHelpers.udp_free_port!()

    route_id =
      E2EHelpers.api_create_route!(base_url, token, %{
        "name" => "e2e_source_thumbnail",
        "enabled" => true
      })

    source_id =
      E2EHelpers.api_create_source!(base_url, token, route_id, %{
        "enabled" => true,
        "name" => "Primary",
        "schema" => "SRT",
        "position" => 0,
        "mode" => "listener",
        "localaddress" => "127.0.0.1",
        "localport" => source_port,
        "thumbnail_enabled" => true,
        "thumbnail_interval_ms" => 1000,
        "thumbnail_capture_policy" => "running"
      })

    :ok =
      E2EHelpers.api_create_destination!(base_url, token, route_id, %{
        "schema" => "UDP",
        "host" => "127.0.0.1",
        "port" => sink_port
      })

    on_exit(fn ->
      E2EHelpers.api_stop_route(base_url, token, route_id)
      E2EHelpers.api_delete_route(base_url, token, route_id)
    end)

    :ok = E2EHelpers.api_start_route!(base_url, token, route_id)

    tx =
      E2EHelpers.start_port_logged!(
        "ffmpeg",
        [
          "-hide_banner",
          "-loglevel",
          "error",
          "-re",
          "-f",
          "lavfi",
          "-i",
          "testsrc2=size=640x360:rate=30",
          "-t",
          "8",
          "-c:v",
          "mpeg2video",
          "-pix_fmt",
          "yuv420p",
          "-f",
          "mpegts",
          "srt://127.0.0.1:#{source_port}?mode=caller"
        ],
        "ffmpeg_thumbnail"
      )

    on_exit(fn -> E2EHelpers.kill_port(tx) end)

    E2EHelpers.wait_for_route_processing!(base_url, token, route_id,
      expected_destination_count: 1,
      timeout_ms: 20_000
    )

    assert E2EHelpers.wait_until(
             fn ->
               case E2EHelpers.http_raw(
                      :get,
                      base_url <> "/api/routes/#{route_id}/sources/#{source_id}/thumbnail",
                      E2EHelpers.auth_headers(token),
                      ""
                    ) do
                 {:ok, 200, _headers, <<0xFF, 0xD8, _rest::binary>>} -> true
                 _ -> false
               end
             end,
             20_000,
             250
           )
  end
end

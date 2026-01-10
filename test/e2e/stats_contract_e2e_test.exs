defmodule HydraSrt.E2E.StatsContractE2ETest do
  use ExUnit.Case, async: false

  alias HydraSrt.TestSupport.E2EHelpers

  @moduletag :e2e

  setup_all do
    E2EHelpers.ensure_e2e_prereqs!()
    {:ok, base_url: E2EHelpers.base_url()}
  end

  test "stats payload contains fields required by graphs (source + per-destination throughput)",
       %{
         base_url: base_url
       } do
    token = E2EHelpers.api_login!(base_url, "admin", "password123")

    source_port = E2EHelpers.tcp_free_port!()
    udp_dest_port = E2EHelpers.udp_free_port!()

    route_id =
      E2EHelpers.api_create_route!(base_url, token, %{
        "name" => "e2e_stats_contract",
        "exportStats" => false,
        "schema" => "SRT",
        "schema_options" => %{
          "localaddress" => "127.0.0.1",
          "localport" => source_port,
          "mode" => "listener"
        }
      })

    on_exit(fn ->
      E2EHelpers.api_stop_route(base_url, token, route_id)
      E2EHelpers.api_delete_route(base_url, token, route_id)
    end)

    :ok =
      E2EHelpers.api_create_destination!(base_url, token, route_id, %{
        "schema" => "UDP",
        "name" => "udp_dest_e2e",
        "schema_options" => %{
          "host" => "127.0.0.1",
          "port" => udp_dest_port
        }
      })

    Phoenix.PubSub.subscribe(HydraSrt.PubSub, "stats:#{route_id}")

    :ok = E2EHelpers.api_start_route!(base_url, token, route_id)
    Process.sleep(750)

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
          "testsrc2=size=1280x720:rate=30",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:sample_rate=48000",
          "-t",
          "5",
          "-c:v",
          "libx264",
          "-preset",
          "veryfast",
          "-tune",
          "zerolatency",
          "-pix_fmt",
          "yuv420p",
          "-g",
          "60",
          "-c:a",
          "aac",
          "-b:a",
          "128k",
          "-ar",
          "48000",
          "-ac",
          "2",
          "-f",
          "mpegts",
          "srt://127.0.0.1:#{source_port}?mode=caller"
        ],
        "ffmpeg_stats_contract"
      )

    on_exit(fn -> E2EHelpers.kill_port(tx) end)

    # Wait for at least one stats frame, then assert required fields exist and have expected types.
    assert_receive {:stats, stats}, 10_000

    assert is_map(stats)
    assert is_map(stats["source"])
    assert is_number(stats["source"]["bytes_in_per_sec"])

    assert is_list(stats["destinations"])
    assert length(stats["destinations"]) >= 1

    dest = hd(stats["destinations"])
    assert is_binary(dest["id"])
    assert is_binary(dest["schema"])
    assert is_binary(dest["name"])
    assert is_number(dest["bytes_out_per_sec"])
  end
end

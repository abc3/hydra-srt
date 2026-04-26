defmodule HydraSrt.E2E.SrtDestinationDisconnectDoesNotBlockUdpE2ETest do
  use ExUnit.Case, async: false

  alias HydraSrt.TestSupport.E2EHelpers

  @moduletag :e2e

  setup_all do
    E2EHelpers.ensure_e2e_prereqs!()
    {:ok, base_url: E2EHelpers.base_url()}
  end

  test "UDP destination keeps forwarding after SRT destination listener disappears", %{
    base_url: base_url
  } do
    token = E2EHelpers.api_login!(base_url, "admin", "password123")

    source_port = E2EHelpers.tcp_free_port!()
    srt_dest_port = E2EHelpers.tcp_free_port!()
    srt_probe_udp_port = E2EHelpers.udp_free_port!()
    udp_dest_port = E2EHelpers.udp_free_port!()

    srt_probe_counter = E2EHelpers.start_udp_counter!(srt_probe_udp_port)
    udp_dest_counter = E2EHelpers.start_udp_counter!(udp_dest_port)

    on_exit(fn ->
      E2EHelpers.stop_udp_counter!(srt_probe_counter)
      E2EHelpers.stop_udp_counter!(udp_dest_counter)
    end)

    route_id =
      E2EHelpers.api_create_route!(base_url, token, %{
        "name" => "e2e_srt_disconnect_does_not_block_udp",
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
        "name" => "udp_dest_stays_alive_e2e",
        "schema_options" => %{
          "host" => "127.0.0.1",
          "port" => udp_dest_port
        }
      })

    :ok =
      E2EHelpers.api_create_destination!(base_url, token, route_id, %{
        "schema" => "SRT",
        "name" => "srt_dest_disconnect_e2e",
        "schema_options" => %{
          "localaddress" => "127.0.0.1",
          "localport" => srt_dest_port,
          "mode" => "caller"
        }
      })

    srt_rx =
      E2EHelpers.start_port_logged!(
        "srt-live-transmit",
        [
          "-v",
          "-stats",
          "1000",
          "-statspf",
          "default",
          "srt://127.0.0.1:#{srt_dest_port}?mode=listener",
          "udp://127.0.0.1:#{srt_probe_udp_port}"
        ],
        "srt-live-transmit-disconnect"
      )

    Process.sleep(E2EHelpers.e2e_startup_sleep_ms())

    :ok = E2EHelpers.api_start_route!(base_url, token, route_id)
    Process.sleep(E2EHelpers.e2e_startup_sleep_ms())

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
          "12",
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
        "ffmpeg_srt_disconnect_udp_alive"
      )

    on_exit(fn ->
      E2EHelpers.kill_port(tx)
      E2EHelpers.kill_port(srt_rx)
    end)

    E2EHelpers.wait_until(
      fn ->
        case E2EHelpers.api_get_route(base_url, token, route_id) do
          {:ok, route} ->
            route["schema_status"] == "processing" and
              length(route["destinations"]) == 2 and
              Enum.all?(route["destinations"], fn destination ->
                destination["status"] == "processing"
              end)

          _ ->
            false
        end
      end,
      10_000,
      250
    )

    assert {:ok, %{bytes: probe_bytes}} =
             E2EHelpers.await_udp_bytes(srt_probe_counter, 20_000, 5_000)

    assert probe_bytes >= 20_000

    assert {:ok, %{bytes: udp_bytes_before_disconnect}} =
             E2EHelpers.await_udp_bytes(udp_dest_counter, 1, 5_000)

    assert udp_bytes_before_disconnect > 0

    :ok = E2EHelpers.kill_port(srt_rx)

    udp_bytes_at_disconnect = E2EHelpers.get_udp_bytes!(udp_dest_counter)

    assert {:ok, %{bytes: udp_bytes_after_disconnect}} =
             E2EHelpers.await_udp_bytes(
               udp_dest_counter,
               udp_bytes_at_disconnect + 188 * 50,
               5_000
             )

    assert udp_bytes_after_disconnect > udp_bytes_at_disconnect
    assert E2EHelpers.await_tag_exit_status("ffmpeg_srt_disconnect_udp_alive", 15_000) == 0
  end
end

defmodule HydraSrt.E2E.InterfaceSelectionE2ETest do
  use ExUnit.Case, async: false

  alias HydraSrt.TestSupport.E2EHelpers

  @moduletag :e2e

  setup_all do
    E2EHelpers.ensure_e2e_prereqs!()
    {:ok, base_url: E2EHelpers.base_url()}
  end

  test "SRT source binds using selected interface and forwards to SRT destination", %{
    base_url: base_url
  } do
    token = E2EHelpers.api_login!(base_url, "admin", "password123")

    interface = %{
      "sys_name" => "e2e_loopback_srt_source",
      "ip" => "127.0.0.1/8",
      "bind_ip" => "127.0.0.1"
    }

    interface_id = create_interface_record!(base_url, token, interface, "e2e-srt-source-iface")

    source_port = E2EHelpers.tcp_free_port!()
    srt_dest_port = E2EHelpers.tcp_free_port!()
    srt_probe_udp_port = E2EHelpers.udp_free_port!()
    srt_probe_counter = E2EHelpers.start_udp_counter!(srt_probe_udp_port)

    on_exit(fn ->
      E2EHelpers.stop_udp_counter!(srt_probe_counter)
      E2EHelpers.api_delete_interface(base_url, token, interface_id)
    end)

    route_id =
      E2EHelpers.api_create_route!(base_url, token, %{
        "name" => "e2e_srt_source_selected_interface",
        "schema" => "SRT",
        "schema_options" => %{
          "interface_sys_name" => interface["sys_name"],
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
        "schema" => "SRT",
        "name" => "srt_dest_from_selected_source_interface_e2e",
        "schema_options" => %{
          "address" => interface["bind_ip"],
          "port" => srt_dest_port,
          "mode" => "caller"
        }
      })

    srt_rx =
      start_srt_probe_listener!(
        "srt-live-transmit-srt-source-selected-interface",
        srt_dest_port,
        srt_probe_udp_port,
        interface["bind_ip"]
      )

    on_exit(fn -> E2EHelpers.kill_port(srt_rx) end)

    :ok = E2EHelpers.api_start_route!(base_url, token, route_id)
    Process.sleep(E2EHelpers.e2e_startup_sleep_ms())

    tx =
      start_ffmpeg_sender!(
        "ffmpeg_srt_source_selected_interface",
        "srt://#{interface["bind_ip"]}:#{source_port}?mode=caller"
      )

    on_exit(fn -> E2EHelpers.kill_port(tx) end)

    E2EHelpers.wait_for_route_processing!(base_url, token, route_id,
      expected_destination_count: 1
    )

    assert {:ok, %{bytes: probe_bytes}} =
             E2EHelpers.await_udp_bytes(srt_probe_counter, 20_000, 5_000)

    assert probe_bytes >= 20_000
    assert E2EHelpers.await_tag_exit_status("ffmpeg_srt_source_selected_interface", 10_000) == 0
  end

  test "UDP source binds using selected interface and forwards to SRT destination", %{
    base_url: base_url
  } do
    token = E2EHelpers.api_login!(base_url, "admin", "password123")

    interface = %{
      "sys_name" => "e2e_loopback_udp_source",
      "ip" => "127.0.0.1/8",
      "bind_ip" => "127.0.0.1"
    }

    interface_id = create_interface_record!(base_url, token, interface, "e2e-udp-source-iface")

    source_port = E2EHelpers.udp_free_port!()
    srt_dest_port = E2EHelpers.tcp_free_port!()
    srt_probe_udp_port = E2EHelpers.udp_free_port!()
    srt_probe_counter = E2EHelpers.start_udp_counter!(srt_probe_udp_port)

    on_exit(fn ->
      E2EHelpers.stop_udp_counter!(srt_probe_counter)
      E2EHelpers.api_delete_interface(base_url, token, interface_id)
    end)

    route_id =
      E2EHelpers.api_create_route!(base_url, token, %{
        "name" => "e2e_udp_source_selected_interface",
        "schema" => "UDP",
        "schema_options" => %{
          "interface_sys_name" => interface["sys_name"],
          "port" => source_port
        }
      })

    on_exit(fn ->
      E2EHelpers.api_stop_route(base_url, token, route_id)
      E2EHelpers.api_delete_route(base_url, token, route_id)
    end)

    :ok =
      E2EHelpers.api_create_destination!(base_url, token, route_id, %{
        "schema" => "SRT",
        "name" => "srt_dest_selected_interface_e2e",
        "schema_options" => %{
          "interface_sys_name" => interface["sys_name"],
          "address" => interface["bind_ip"],
          "port" => srt_dest_port,
          "mode" => "caller"
        }
      })

    srt_rx =
      start_srt_probe_listener!(
        "srt-live-transmit-udp-source-selected-interface",
        srt_dest_port,
        srt_probe_udp_port,
        interface["bind_ip"]
      )

    Process.sleep(E2EHelpers.e2e_startup_sleep_ms())
    :ok = E2EHelpers.api_start_route!(base_url, token, route_id)
    Process.sleep(E2EHelpers.e2e_startup_sleep_ms())

    on_exit(fn -> E2EHelpers.kill_port(srt_rx) end)

    :ok = E2EHelpers.send_udp_burst!(interface["bind_ip"], source_port)

    wait_for_route_schema_processing!(base_url, token, route_id)

    assert {:ok, %{bytes: probe_bytes}} =
             E2EHelpers.await_udp_bytes(srt_probe_counter, 20_000, 5_000)

    assert probe_bytes >= 20_000
  end

  test "SRT destination caller uses selected interface and reaches downstream listener", %{
    base_url: base_url
  } do
    token = E2EHelpers.api_login!(base_url, "admin", "password123")

    interface = %{
      "sys_name" => "e2e_loopback_srt_destination",
      "ip" => "127.0.0.1/8",
      "bind_ip" => "127.0.0.1"
    }

    interface_id = create_interface_record!(base_url, token, interface, "e2e-srt-dest-iface")

    source_port = E2EHelpers.tcp_free_port!()
    srt_dest_port = E2EHelpers.tcp_free_port!()
    srt_probe_udp_port = E2EHelpers.udp_free_port!()
    srt_probe_counter = E2EHelpers.start_udp_counter!(srt_probe_udp_port)

    on_exit(fn ->
      E2EHelpers.stop_udp_counter!(srt_probe_counter)
      E2EHelpers.api_delete_interface(base_url, token, interface_id)
    end)

    route_id =
      E2EHelpers.api_create_route!(base_url, token, %{
        "name" => "e2e_srt_destination_selected_interface",
        "schema" => "SRT",
        "schema_options" => %{
          "localaddress" => interface["bind_ip"],
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
        "schema" => "SRT",
        "name" => "srt_dest_caller_selected_interface_e2e",
        "schema_options" => %{
          "interface_sys_name" => interface["sys_name"],
          "address" => interface["bind_ip"],
          "port" => srt_dest_port,
          "mode" => "caller"
        }
      })

    srt_rx =
      start_srt_probe_listener!(
        "srt-live-transmit-srt-destination-selected-interface",
        srt_dest_port,
        srt_probe_udp_port,
        interface["bind_ip"]
      )

    Process.sleep(E2EHelpers.e2e_startup_sleep_ms())
    :ok = E2EHelpers.api_start_route!(base_url, token, route_id)
    Process.sleep(E2EHelpers.e2e_startup_sleep_ms())

    tx =
      start_ffmpeg_sender!(
        "ffmpeg_srt_destination_selected_interface",
        "srt://#{interface["bind_ip"]}:#{source_port}?mode=caller"
      )

    on_exit(fn ->
      E2EHelpers.kill_port(tx)
      E2EHelpers.kill_port(srt_rx)
    end)

    E2EHelpers.wait_for_route_processing!(base_url, token, route_id,
      expected_destination_count: 1
    )

    assert {:ok, %{bytes: probe_bytes}} =
             E2EHelpers.await_udp_bytes(srt_probe_counter, 20_000, 5_000)

    assert probe_bytes >= 20_000

    assert E2EHelpers.await_tag_exit_status("ffmpeg_srt_destination_selected_interface", 10_000) ==
             0
  end

  test "UDP multicast destination uses selected interface and delivers packets to multicast listeners",
       %{
         base_url: base_url
       } do
    token = E2EHelpers.api_login!(base_url, "admin", "password123")
    interface = E2EHelpers.discover_ipv4_system_interface!(prefer_non_loopback: true)

    multicast_supported? = E2EHelpers.local_multicast_roundtrip_supported?(interface["bind_ip"])

    unless multicast_supported? do
      IO.puts(
        "WARN: skipping multicast destination E2E on #{interface["sys_name"]}; local multicast roundtrip unsupported"
      )
    end

    if multicast_supported? do
      interface_id =
        create_interface_record!(base_url, token, interface, "e2e-udp-mcast-dest-iface")

      source_port = E2EHelpers.udp_free_port!()
      multicast_port = E2EHelpers.udp_free_port!()
      multicast_group = "239.255.10.10"

      multicast_counter =
        E2EHelpers.start_multicast_udp_counter!(
          multicast_group,
          interface["bind_ip"],
          multicast_port
        )

      on_exit(fn ->
        E2EHelpers.stop_udp_counter!(multicast_counter)
        E2EHelpers.api_delete_interface(base_url, token, interface_id)
      end)

      route_id =
        E2EHelpers.api_create_route!(base_url, token, %{
          "name" => "e2e_udp_multicast_destination_selected_interface",
          "schema" => "UDP",
          "schema_options" => %{
            "interface_sys_name" => interface["sys_name"],
            "port" => source_port
          }
        })

      on_exit(fn ->
        E2EHelpers.api_stop_route(base_url, token, route_id)
        E2EHelpers.api_delete_route(base_url, token, route_id)
      end)

      :ok =
        E2EHelpers.api_create_destination!(base_url, token, route_id, %{
          "schema" => "UDP",
          "name" => "udp_multicast_dest_selected_interface_e2e",
          "schema_options" => %{
            "host" => multicast_group,
            "port" => multicast_port,
            "interface_sys_name" => interface["sys_name"]
          }
        })

      :ok = E2EHelpers.api_start_route!(base_url, token, route_id)
      Process.sleep(E2EHelpers.e2e_startup_sleep_ms())
      :ok = E2EHelpers.send_udp_burst!(interface["bind_ip"], source_port)

      wait_for_route_schema_processing!(base_url, token, route_id)

      assert {:ok, %{bytes: multicast_bytes}} =
               E2EHelpers.await_udp_bytes(multicast_counter, 20_000, 8_000)

      assert multicast_bytes >= 20_000
    else
      assert true
    end
  end

  test "UDP multicast source uses selected interface and forwards packets to destination", %{
    base_url: base_url
  } do
    token = E2EHelpers.api_login!(base_url, "admin", "password123")
    interface = E2EHelpers.discover_ipv4_system_interface!(prefer_non_loopback: true)

    multicast_supported? = E2EHelpers.local_multicast_roundtrip_supported?(interface["bind_ip"])

    unless multicast_supported? do
      IO.puts(
        "WARN: skipping multicast source E2E on #{interface["sys_name"]}; local multicast roundtrip unsupported"
      )
    end

    if multicast_supported? do
      interface_id =
        create_interface_record!(base_url, token, interface, "e2e-udp-mcast-source-iface")

      multicast_group = "239.255.10.11"
      source_port = E2EHelpers.udp_free_port!()
      udp_dest_port = E2EHelpers.udp_free_port!()
      udp_counter = E2EHelpers.start_udp_counter!(udp_dest_port)

      on_exit(fn ->
        E2EHelpers.stop_udp_counter!(udp_counter)
        E2EHelpers.api_delete_interface(base_url, token, interface_id)
      end)

      route_id =
        E2EHelpers.api_create_route!(base_url, token, %{
          "name" => "e2e_udp_multicast_source_selected_interface",
          "schema" => "UDP",
          "schema_options" => %{
            "address" => multicast_group,
            "port" => source_port,
            "interface_sys_name" => interface["sys_name"]
          }
        })

      on_exit(fn ->
        E2EHelpers.api_stop_route(base_url, token, route_id)
        E2EHelpers.api_delete_route(base_url, token, route_id)
      end)

      :ok =
        E2EHelpers.api_create_destination!(base_url, token, route_id, %{
          "schema" => "UDP",
          "name" => "udp_dest_from_multicast_source_e2e",
          "schema_options" => %{
            "host" => "127.0.0.1",
            "port" => udp_dest_port
          }
        })

      :ok = E2EHelpers.api_start_route!(base_url, token, route_id)
      Process.sleep(E2EHelpers.e2e_startup_sleep_ms())

      :ok =
        E2EHelpers.send_multicast_udp_burst!(multicast_group, source_port, interface["bind_ip"])

      wait_for_route_schema_processing!(base_url, token, route_id)

      assert {:ok, %{bytes: udp_bytes}} = E2EHelpers.await_udp_bytes(udp_counter, 20_000, 8_000)
      assert udp_bytes >= 20_000
    else
      assert true
    end
  end

  defp create_interface_record!(base_url, token, interface, name_prefix) do
    E2EHelpers.api_create_interface!(base_url, token, %{
      "name" => "#{name_prefix}-#{interface["sys_name"]}",
      "sys_name" => interface["sys_name"],
      "ip" => interface["ip"]
    })
  end

  defp start_srt_probe_listener!(tag, srt_port, udp_probe_port, listen_host) do
    E2EHelpers.start_port_logged!(
      "srt-live-transmit",
      [
        "-v",
        "-stats",
        "1000",
        "-statspf",
        "default",
        "srt://#{listen_host}:#{srt_port}?mode=listener",
        "udp://127.0.0.1:#{udp_probe_port}"
      ],
      tag
    )
  end

  defp start_ffmpeg_sender!(tag, output_url, duration_seconds \\ 6) do
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
        Integer.to_string(duration_seconds),
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
        output_url
      ],
      tag
    )
  end

  defp wait_for_route_schema_processing!(base_url, token, route_id) do
    E2EHelpers.wait_until(
      fn ->
        case E2EHelpers.api_get_route(base_url, token, route_id) do
          {:ok, route} -> route["schema_status"] == "processing"
          _ -> false
        end
      end,
      10_000,
      250
    )
  end
end

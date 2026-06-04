defmodule HydraSrt.E2E.UdpMulticastPipelineE2ETest do
  use ExUnit.Case, async: false

  require Logger

  alias HydraSrt.TestSupport.E2EHelpers

  @moduletag :e2e

  setup_all do
    E2EHelpers.ensure_e2e_prereqs!()
    {:ok, base_url: E2EHelpers.base_url()}
  end

  test "UDP multicast source forwards MPEG-TS packets to UDP destination", %{base_url: base_url} do
    token = E2EHelpers.api_login!(base_url, "admin", "password123")
    interface = E2EHelpers.discover_ipv4_system_interface!(require_multicast: true)
    group_ip = "239.255.20.21"
    source_port = E2EHelpers.udp_free_port!()
    dest_port = E2EHelpers.udp_free_port!()
    dest_counter = E2EHelpers.start_udp_counter!(dest_port)

    on_exit(fn -> E2EHelpers.stop_udp_counter!(dest_counter) end)

    if E2EHelpers.local_multicast_roundtrip_supported?(interface["bind_ip"]) do
      route_id =
        E2EHelpers.api_create_route!(base_url, token, %{
          "name" => "e2e_udp_multicast_source",
          "schema" => "UDP",
          "address" => group_ip,
          "port" => source_port,
          "multicast" => true,
          "interface_sys_name" => interface["sys_name"]
        })

      on_exit(fn ->
        E2EHelpers.api_stop_route(base_url, token, route_id)
        E2EHelpers.api_delete_route(base_url, token, route_id)
      end)

      :ok =
        E2EHelpers.api_create_destination!(base_url, token, route_id, %{
          "schema" => "UDP",
          "name" => "udp_dest_from_multicast_source_e2e",
          "host" => "127.0.0.1",
          "port" => dest_port
        })

      :ok = E2EHelpers.api_start_route!(base_url, token, route_id)
      Process.sleep(E2EHelpers.e2e_startup_sleep_ms())

      :ok =
        E2EHelpers.send_multicast_udp_burst!(
          group_ip,
          source_port,
          interface["bind_ip"],
          packet_count: 250,
          packet_size: 1316
        )

      assert {:ok, %{bytes: dest_bytes}} =
               E2EHelpers.await_udp_bytes(dest_counter, 20_000, 5_000)

      assert dest_bytes >= 20_000
    else
      Logger.warning(
        "Skipping UDP multicast source E2E because local multicast roundtrip is not supported on #{interface["sys_name"]}"
      )

      assert true
    end
  end
end

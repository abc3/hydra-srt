defmodule HydraSrt.E2E.Native.RsNativeSrtSourceDisconnectTest do
  use ExUnit.Case, async: false

  alias HydraSrt.Destinations
  alias HydraSrt.E2E.Native.Helpers
  alias HydraSrt.E2E.Native.ProcessRegistry
  alias HydraSrt.E2E.Native.UdpListener
  alias HydraSrt.Routes
  alias HydraSrt.Sources
  alias HydraSrt.TestSupport.E2EHelpers

  @moduletag :native_e2e

  setup_all do
    original_repo_config = HydraSrt.Repo.config()
    original_rtmp_port = Application.fetch_env!(:hydra_srt, :rtmp_port)
    original_endpoint_config = Application.get_env(:hydra_srt, HydraSrtWeb.Endpoint, [])
    original_e2e_database_path = System.get_env("E2E_DATABASE_PATH")

    if is_pid(Process.whereis(HydraSrt.Supervisor)) do
      :ok = Application.stop(:hydra_srt)
    end

    E2EHelpers.ensure_native_built!()
    E2EHelpers.ensure_api_auth_config!()
    E2EHelpers.ensure_repo_config_for_e2e!()
    E2EHelpers.ensure_repo_migrated_for_e2e!()
    E2EHelpers.ensure_app_started!()
    E2EHelpers.ensure_cachex_started!()
    Helpers.ensure_prereqs!()

    on_exit(fn ->
      _ = Application.stop(:hydra_srt)
      Application.put_env(:hydra_srt, HydraSrt.Repo, original_repo_config)
      Application.put_env(:hydra_srt, :rtmp_port, original_rtmp_port)
      Application.put_env(:hydra_srt, HydraSrtWeb.Endpoint, original_endpoint_config)

      case original_e2e_database_path do
        nil -> System.delete_env("E2E_DATABASE_PATH")
        path -> System.put_env("E2E_DATABASE_PATH", path)
      end

      {:ok, _started} = Application.ensure_all_started(:hydra_srt)
    end)

    :ok
  end

  setup do
    ProcessRegistry.cleanup_all!()
    source_port = Helpers.free_srt_port!()
    udp_port = Helpers.free_udp_port!()
    route_name = "rs_srt_source_disconnect_#{System.unique_integer([:positive])}"

    {:ok, udp_listener} = UdpListener.start_link(port: udp_port, test_pid: self())
    {:ok, route} = Routes.create(%{"name" => route_name, "enabled" => true})
    route_id = route["id"]

    {:ok, _source} =
      Sources.create(route_id, %{
        "enabled" => true,
        "name" => "SRT listener",
        "schema" => "SRT",
        "mode" => "listener",
        "localaddress" => "127.0.0.1",
        "localport" => source_port,
        "auto_reconnect" => true,
        "position" => 0
      })

    {:ok, _destination} =
      Destinations.create(route_id, %{
        "enabled" => true,
        "name" => "UDP sink",
        "schema" => "UDP",
        "host" => "127.0.0.1",
        "port" => udp_port
      })

    assert {:ok, _supervisor_pid} = HydraSrt.start_route(route_id)

    on_exit(fn ->
      _ = HydraSrt.stop_route(route_id)
      _ = Routes.delete(route_id)
      ProcessRegistry.cleanup_all!()

      if Process.alive?(udp_listener) do
        GenServer.stop(udp_listener, :normal, 5_000)
      end
    end)

    {:ok,
     route_id: route_id, source_port: source_port, udp_port: udp_port, udp_listener: udp_listener}
  end

  test "SRT listener route survives caller disconnect and forwards after reconnect", %{
    route_id: route_id,
    source_port: source_port,
    udp_port: udp_port,
    udp_listener: udp_listener
  } do
    default_config = Helpers.srt_to_udp_config(source_port, udp_port)
    assert default_config["source"]["srt"]["keep_listening"]

    explicit_false_config =
      Helpers.srt_to_udp_config(source_port, udp_port, keep_listening: false)

    refute explicit_false_config["source"]["srt"]["keep_listening"]

    sender = Helpers.start_ffmpeg_sender!(source_port, duration: 60)
    on_exit(fn -> Helpers.stop_os_process!(sender) end)

    assert {:ok, %{bytes: initial_bytes}} =
             UdpListener.await_bytes(udp_listener, 10_000, 20_000)

    assert {:ok, handler_pid} = HydraSrt.get_route_handler(route_id)
    assert Process.alive?(handler_pid)

    :ok = Helpers.stop_os_process!(sender)

    assert :ok =
             Helpers.wait_until(
               fn -> not Helpers.sender_alive?(sender) end,
               5_000,
               50
             )

    assert :ok =
             Helpers.wait_until(
               fn ->
                 with {:ok, route} <- HydraSrt.Db.get_route(route_id, true),
                      {:ok, handler} <- HydraSrt.get_route_handler(route_id) do
                   Process.alive?(handler) and
                     HydraSrt.live_route_status?(route["schema_status"] || route["status"])
                 else
                   _ -> false
                 end
               end,
               10_000,
               100
             )

    case HydraSrt.start_route(route_id) do
      {:ok, _supervisor_pid} ->
        assert {:ok, restarted_handler} = HydraSrt.get_route_handler(route_id)
        assert Process.alive?(restarted_handler)

      {:error, {:already_started, _supervisor_pid}} ->
        assert {:ok, live_handler} = HydraSrt.get_route_handler(route_id)
        assert Process.alive?(live_handler)

      other ->
        flunk("unexpected start result after caller disconnect: #{inspect(other)}")
    end

    assert {:ok, route_after_disconnect} = HydraSrt.Db.get_route(route_id, true)

    assert HydraSrt.live_route_status?(
             route_after_disconnect["schema_status"] || route_after_disconnect["status"]
           )

    reconnected_sender = Helpers.start_ffmpeg_sender!(source_port, duration: 60)
    on_exit(fn -> Helpers.stop_os_process!(reconnected_sender) end)

    assert {:ok, %{bytes: reconnected_bytes}} =
             UdpListener.await_bytes(udp_listener, initial_bytes + 10_000, 20_000)

    assert reconnected_bytes > initial_bytes
  end
end

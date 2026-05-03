defmodule HydraSrt.RouteHandlerFailoverTest do
  use HydraSrt.DataCase, async: false

  alias HydraSrt.Db
  alias HydraSrt.DbFixtures
  alias HydraSrt.RouteHandler

  defmodule ProbeStub do
    def probe(_source), do: {:ok, %{"ok" => true}}
  end

  setup do
    route =
      DbFixtures.route_fixture(%{
        "name" => "failover-route",
        "backup_config" => %{"mode" => "passive", "switch_after_ms" => 1000, "cooldown_ms" => 100}
      })

    primary =
      DbFixtures.source_fixture(route, %{
        "position" => 0,
        "name" => "primary",
        "schema" => "UDP",
        "schema_options" => %{"address" => "127.0.0.1", "port" => 15_000}
      })

    backup =
      DbFixtures.source_fixture(route, %{
        "position" => 1,
        "name" => "backup",
        "schema" => "UDP",
        "schema_options" => %{"address" => "127.0.0.1", "port" => 15_001}
      })

    {:ok, _route} = Db.set_route_active_source(route["id"], primary["id"], "manual")

    {:ok, _pid} = HydraSrt.start_route(route["id"])
    {:ok, handler_pid} = wait_for_route_handler(route["id"])

    on_exit(fn ->
      _ = HydraSrt.stop_route(route["id"])
    end)

    %{route_id: route["id"], primary: primary, backup: backup, handler_pid: handler_pid}
  end

  test "manual switch cast updates active source", ctx do
    :ok = RouteHandler.switch_source(ctx.handler_pid, ctx.backup["id"], "manual")

    wait_until(fn ->
      {:ok, route} = Db.get_route(ctx.route_id, true)
      route["active_source_id"] == ctx.backup["id"] and route["last_switch_reason"] == "manual"
    end)
  end

  test "pipeline failed event triggers failover to next enabled source", ctx do
    {_, data} = :sys.get_state(ctx.handler_pid)
    port = data.port

    send(
      ctx.handler_pid,
      {port,
       {:data, "{\"event\":\"pipeline_status\",\"status\":\"failed\",\"reason\":\"test\"}\n"}}
    )

    wait_until(fn ->
      {:ok, route} = Db.get_route(ctx.route_id, true)
      route["active_source_id"] == ctx.backup["id"] and route["last_switch_reason"] == "failed"
    end)
  end

  test "manual switch to disabled source is ignored", ctx do
    {:ok, _updated_source} =
      Db.update_source(ctx.route_id, ctx.backup["id"], %{"enabled" => false})

    :ok = RouteHandler.switch_source(ctx.handler_pid, ctx.backup["id"], "manual")
    Process.sleep(150)

    {:ok, route} = Db.get_route(ctx.route_id, true)
    assert route["active_source_id"] == ctx.primary["id"]
  end

  test "reconnecting switches only after debounce window on repeated reconnecting events", ctx do
    {_, data} = :sys.get_state(ctx.handler_pid)
    port = data.port

    send(
      ctx.handler_pid,
      {port, {:data, "{\"event\":\"pipeline_status\",\"status\":\"reconnecting\"}\n"}}
    )

    Process.sleep(1_100)

    send(
      ctx.handler_pid,
      {port, {:data, "{\"event\":\"pipeline_status\",\"status\":\"reconnecting\"}\n"}}
    )

    wait_until(fn ->
      {:ok, route} = Db.get_route(ctx.route_id, true)

      route["active_source_id"] == ctx.backup["id"] ||
        route["last_switch_reason"] == "reconnecting"
    end)
  end

  test "processing status resets reconnecting debounce and prevents switch", ctx do
    {_, data} = :sys.get_state(ctx.handler_pid)
    port = data.port

    send(
      ctx.handler_pid,
      {port, {:data, "{\"event\":\"pipeline_status\",\"status\":\"reconnecting\"}\n"}}
    )

    wait_until(fn ->
      {_, state_data} = :sys.get_state(ctx.handler_pid)
      is_integer(state_data.reconnecting_since_ms)
    end)

    send(
      ctx.handler_pid,
      {port, {:data, "{\"event\":\"pipeline_status\",\"status\":\"processing\"}\n"}}
    )

    wait_until(fn ->
      {_, state_data} = :sys.get_state(ctx.handler_pid)
      is_nil(state_data.reconnecting_since_ms)
    end)
  end

  test "cooldown prevents immediate second zero-bitrate switch in active mode" do
    route =
      DbFixtures.route_fixture(%{
        "name" => "active-cooldown-route",
        "backup_config" => %{"mode" => "active", "switch_after_ms" => 1000, "cooldown_ms" => 5000}
      })

    primary =
      DbFixtures.source_fixture(route, %{
        "position" => 0,
        "name" => "primary",
        "schema_options" => %{"address" => "127.0.0.1", "port" => 16_000}
      })

    backup1 =
      DbFixtures.source_fixture(route, %{
        "position" => 1,
        "name" => "backup-1",
        "schema_options" => %{"address" => "127.0.0.1", "port" => 16_001}
      })

    _backup2 =
      DbFixtures.source_fixture(route, %{
        "position" => 2,
        "name" => "backup-2",
        "schema_options" => %{"address" => "127.0.0.1", "port" => 16_002}
      })

    {:ok, _route} = Db.set_route_active_source(route["id"], primary["id"], "manual")
    {:ok, _pid} = HydraSrt.start_route(route["id"])
    {:ok, handler_pid} = wait_for_route_handler(route["id"])

    on_exit(fn ->
      _ = HydraSrt.stop_route(route["id"])
    end)

    {_, data} = :sys.get_state(handler_pid)
    port = data.port

    # First zero-bitrate tick switches from primary to backup-1.
    send(
      handler_pid,
      {port, {:data, "{\"source\":{\"bytes_in_per_sec\":0},\"destinations\":[]}\n"}}
    )

    wait_until(fn ->
      {:ok, current} = Db.get_route(route["id"], true)
      current["active_source_id"] == backup1["id"]
    end)

    # The port is reopened after switch; pick current live port before second tick.
    {_, state_after_first_switch} = :sys.get_state(handler_pid)
    live_port = state_after_first_switch.port

    # Immediate next zero-bitrate tick is inside cooldown and must not switch to backup-2.
    send(
      handler_pid,
      {live_port, {:data, "{\"source\":{\"bytes_in_per_sec\":0},\"destinations\":[]}\n"}}
    )

    Process.sleep(250)

    {:ok, after_second_tick} = Db.get_route(route["id"], true)
    assert after_second_tick["active_source_id"] == backup1["id"]
  end

  test "active mode probes primary and returns when stable window is satisfied" do
    Application.put_env(:hydra_srt, :source_probe_module, ProbeStub)

    route =
      DbFixtures.route_fixture(%{
        "name" => "active-return-route",
        "backup_config" => %{
          "mode" => "active",
          "switch_after_ms" => 1000,
          "cooldown_ms" => 0,
          "probe_interval_ms" => 0,
          "primary_stable_ms" => 0
        }
      })

    primary =
      DbFixtures.source_fixture(route, %{
        "position" => 0,
        "name" => "primary",
        "schema_options" => %{"address" => "127.0.0.1", "port" => 17_000}
      })

    backup =
      DbFixtures.source_fixture(route, %{
        "position" => 1,
        "name" => "backup",
        "schema_options" => %{"address" => "127.0.0.1", "port" => 17_001}
      })

    {:ok, _route} = Db.set_route_active_source(route["id"], backup["id"], "manual")
    {:ok, _pid} = HydraSrt.start_route(route["id"])
    {:ok, handler_pid} = wait_for_route_handler(route["id"])

    on_exit(fn ->
      Application.delete_env(:hydra_srt, :source_probe_module)
      _ = HydraSrt.stop_route(route["id"])
    end)

    {_, data} = :sys.get_state(handler_pid)
    port = data.port

    send(
      handler_pid,
      {port, {:data, "{\"source\":{\"bytes_in_per_sec\":1000},\"destinations\":[]}\n"}}
    )

    wait_until(fn ->
      {:ok, current} = Db.get_route(route["id"], true)

      current["active_source_id"] == primary["id"] and
        current["last_switch_reason"] == "primary_recovered"
    end)
  end

  defp wait_for_route_handler(route_id, attempts \\ 60)

  defp wait_for_route_handler(_route_id, 0), do: {:error, :timeout}

  defp wait_for_route_handler(route_id, attempts) do
    case HydraSrt.get_route_handler(route_id) do
      {:ok, pid} ->
        {:ok, pid}

      _ ->
        Process.sleep(50)
        wait_for_route_handler(route_id, attempts - 1)
    end
  end

  defp wait_until(fun, attempts \\ 80)

  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(50)
      wait_until(fun, attempts - 1)
    end
  end
end

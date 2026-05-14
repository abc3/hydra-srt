defmodule HydraSrt.RouteHandlerFailoverTest do
  use ExUnit.Case

  alias HydraSrt.Db
  alias HydraSrt.RouteHandler

  @route_id "test-route"

  setup do
    :meck.new(Db, [:passthrough])
    :meck.new(HydraSrt, [:passthrough])
    :meck.new(HydraSrt.Stats.EventLogger, [:passthrough])

    on_exit(fn ->
      :meck.unload()
    end)

    :ok
  end

  test "switch_source schedules retry with cleared port when target source cannot initialize" do
    valid_route = route_with_sources([valid_source("s1", 4000), valid_source("s2", 4001)], "s1")
    broken_route = route_with_sources([valid_source("s1", 4000), broken_source("s2")], "s1")

    {:ok, call_counter} = Agent.start_link(fn -> 0 end)

    :meck.expect(Db, :get_route, fn
      @route_id, true ->
        # 1: init/start, 2: switch pre-check, 3+: switch opens broken source
        idx = Agent.get_and_update(call_counter, fn n -> {n, n + 1} end)

        if idx < 2 do
          {:ok, valid_route}
        else
          {:ok, broken_route}
        end

      _id, _include_dest ->
        {:error, :not_found}
    end)

    :meck.expect(Db, :set_route_active_source, fn _, _, _ -> {:ok, valid_route} end)
    :meck.expect(Db, :update_route_runtime_status, fn _, _ -> {:ok, valid_route} end)
    :meck.expect(HydraSrt, :set_route_runtime_status, fn _, _ -> {:ok, %{}} end)
    :meck.expect(HydraSrt, :mark_route_started, fn _ -> {:ok, %{}} end)
    :meck.expect(HydraSrt, :mark_route_failed, fn _ -> {:ok, %{}} end)
    :meck.expect(HydraSrt, :mark_route_stopped, fn _ -> {:ok, %{}} end)
    :meck.expect(HydraSrt, :mark_route_terminated, fn _ -> {:ok, %{}} end)

    {:ok, pid} = RouteHandler.start_link(%{id: @route_id})

    assert_eventually(fn ->
      {_state_name, data} = :sys.get_state(pid)
      is_port(data.port) and data.active_source_id == "s1"
    end)

    RouteHandler.switch_source(pid, "s2")

    assert_eventually(fn ->
      {_state_name, data} = :sys.get_state(pid)
      data.port == nil and data.retry_scheduled? == true and data.recovering? == true
    end)

    :gen_statem.stop(pid)
    Agent.stop(call_counter)
  end

  defp route_with_sources(sources, active_source_id) do
    %{
      "id" => @route_id,
      "active_source_id" => active_source_id,
      "enabled" => true,
      "sources" => sources,
      "backup_mode" => "passive",
      "backup_switch_after_ms" => 3000,
      "backup_cooldown_ms" => 10_000,
      "backup_primary_stable_ms" => 15_000,
      "backup_probe_interval_ms" => 5000
    }
  end

  defp valid_source(id, localport) do
    %{
      "id" => id,
      "position" => if(id == "s1", do: 0, else: 1),
      "enabled" => true,
      "schema" => "SRT",
      "mode" => "listener",
      "localaddress" => "127.0.0.1",
      "localport" => localport
    }
  end

  defp broken_source(id) do
    %{
      "id" => id,
      "position" => 1,
      "enabled" => true
    }
  end

  defp assert_eventually(fun, attempts \\ 50)
  defp assert_eventually(_fun, 0), do: flunk("condition was not satisfied in time")

  defp assert_eventually(fun, attempts) when is_function(fun, 0) and attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
    end
  end
end

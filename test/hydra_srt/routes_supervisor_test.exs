defmodule HydraSrt.RoutesSupervisorTest do
  use ExUnit.Case, async: false

  defmodule TestRouteHandler do
    use GenServer

    @spec start_link(map()) :: GenServer.on_start()
    def start_link(_args), do: GenServer.start_link(__MODULE__, %{})

    @impl true
    def init(state), do: {:ok, state}
  end

  setup do
    :ok = :meck.new(HydraSrt.RouteHandler, [:passthrough])

    :meck.expect(HydraSrt.RouteHandler, :start_link, fn args ->
      TestRouteHandler.start_link(args)
    end)

    on_exit(fn -> :meck.unload() end)
    :ok
  end

  test "stopping the route handler also stops its supervisor" do
    id = unique_route_id()
    assert {:ok, supervisor_pid} = HydraSrt.start_route(id)
    assert {:ok, handler_pid} = HydraSrt.get_route_handler(id)

    supervisor_ref = Process.monitor(supervisor_pid)
    assert :ok = Supervisor.stop(handler_pid, :normal)
    assert_receive {:DOWN, ^supervisor_ref, :process, ^supervisor_pid, :shutdown}
    assert_syn_unregistered(id)
  end

  test "start_route succeeds after the handler exits normally" do
    id = unique_route_id()
    assert {:ok, first_supervisor_pid} = HydraSrt.start_route(id)
    assert {:ok, first_handler_pid} = HydraSrt.get_route_handler(id)

    supervisor_ref = Process.monitor(first_supervisor_pid)
    assert :ok = Supervisor.stop(first_handler_pid, :normal)
    assert_receive {:DOWN, ^supervisor_ref, :process, ^first_supervisor_pid, :shutdown}

    assert {:ok, second_supervisor_pid} = HydraSrt.start_route(id)
    assert second_supervisor_pid != first_supervisor_pid
    assert {:ok, second_handler_pid} = HydraSrt.get_route_handler(id)
    assert Process.alive?(second_handler_pid)

    assert :ok = Supervisor.stop(second_supervisor_pid, :normal)
  end

  test "start_route keeps a running route and returns already_started" do
    id = unique_route_id()
    assert {:ok, supervisor_pid} = HydraSrt.start_route(id)
    assert {:ok, handler_pid} = HydraSrt.get_route_handler(id)

    assert {:error, {:already_started, ^supervisor_pid}} = HydraSrt.start_route(id)
    assert {:ok, ^handler_pid} = HydraSrt.get_route_handler(id)
    assert Process.alive?(handler_pid)

    assert :ok = Supervisor.stop(supervisor_pid, :normal)
  end

  test "start_route heals a childless registered supervisor" do
    id = unique_route_id()
    {:ok, zombie_pid} = Supervisor.start_link([], strategy: :one_for_one)
    assert :ok = :syn.register(:routes, id, zombie_pid)

    on_exit(fn ->
      if Process.alive?(zombie_pid), do: Supervisor.stop(zombie_pid, :normal)
    end)

    assert {:ok, supervisor_pid} = HydraSrt.start_route(id)
    refute supervisor_pid == zombie_pid
    assert {:ok, handler_pid} = HydraSrt.get_route_handler(id)
    assert Process.alive?(handler_pid)

    assert :ok = Supervisor.stop(supervisor_pid, :normal)
  end

  test "start_route never kills a route whose handler probe failed" do
    id = unique_route_id()

    # A process registered as a route that never answers which_children stands in
    # for a hung supervisor: the probe times out instead of proving anything.
    hung_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert :ok = :syn.register(:routes, id, hung_pid)
    on_exit(fn -> if Process.alive?(hung_pid), do: send(hung_pid, :stop) end)

    assert {:error, :route_handler_probe_failed} = HydraSrt.get_route_handler(id)
    assert {:error, {:already_started, ^hung_pid}} = HydraSrt.start_route(id)
    assert Process.alive?(hung_pid), "a hung supervisor must not be killed and restarted"
  end

  @spec unique_route_id() :: String.t()
  def unique_route_id, do: "i1-route-#{System.unique_integer([:positive])}"

  @spec assert_syn_unregistered(String.t()) :: :ok
  def assert_syn_unregistered(id), do: wait_for_syn_unregistered(id, 50)

  @spec wait_for_syn_unregistered(String.t(), non_neg_integer()) :: :ok
  def wait_for_syn_unregistered(_id, 0), do: flunk("route registration was not removed")

  def wait_for_syn_unregistered(id, attempts) do
    case :syn.lookup(:routes, id) do
      :undefined ->
        :ok

      _ ->
        receive do
        after
          20 -> wait_for_syn_unregistered(id, attempts - 1)
        end
    end
  end
end

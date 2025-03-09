defmodule HydraSrt.RoutesSupervisor do
  @moduledoc false
  use Supervisor

  require Logger
  alias HydraSrt.RouteHandler

  def start_link(args) do
    name = {:via, :syn, {:routes, args.id}}
    Supervisor.start_link(__MODULE__, args, name: name)
  end

  @impl true
  def init(args) do
    children = [
      %{
        id: {:route_handler, args.id},
        start: {RouteHandler, :start_link, [args]},
        restart: :transient,
        type: :worker
      }
    ]

    Supervisor.init(children,
      strategy: :one_for_all,
      max_restarts: 10,
      max_seconds: 60
    )
  end

  def child_spec(args) do
    %{
      id: args.id,
      start: {__MODULE__, :start_link, [args]},
      restart: :transient
    }
  end
end

defmodule HydraSrtWeb.RouteJSON do
  alias HydraSrt.Api.Route

  @doc """
  Renders a list of routes.
  """
  def index(%{routes: routes}) do
    %{data: for(route <- routes, do: data(route))}
  end

  @doc """
  Renders a single route.
  """
  def show(%{route: route}) do
    %{data: data(route)}
  end

  @doc false
  def data(%Route{} = route) do
    %{
      id: route.id,
      enabled: route.enabled,
      name: route.name,
      alias: route.alias,
      status: route.status,
      source: route.source,
      destinations: route.destinations_legacy || [],
      started_at: route.started_at,
      stopped_at: route.stopped_at
    }
  end
end

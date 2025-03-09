defmodule HydraSrtWeb.DestinationJSON do
  alias HydraSrt.Api.Destination

  @doc """
  Renders a list of destinations.
  """
  def index(%{destinations: destinations}) do
    %{data: for(destination <- destinations, do: data(destination))}
  end

  @doc """
  Renders a single destination.
  """
  def show(%{destination: destination}) do
    %{data: data(destination)}
  end

  defp data(%Destination{} = destination) do
    %{
      id: destination.id,
      enabled: destination.enabled,
      name: destination.name,
      alias: destination.alias,
      status: destination.status,
      started_at: destination.started_at,
      stopped_at: destination.stopped_at
    }
  end
end

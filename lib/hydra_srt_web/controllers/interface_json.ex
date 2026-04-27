defmodule HydraSrtWeb.InterfaceJSON do
  alias HydraSrt.Api.Interface

  @doc """
  Renders a list of interfaces.
  """
  def index(%{interfaces: interfaces}) do
    %{data: for(interface <- interfaces, do: data(interface))}
  end

  @doc """
  Renders a single interface.
  """
  def show(%{interface: interface}) do
    %{data: data(interface)}
  end

  defp data(%Interface{} = interface) do
    %{
      id: interface.id,
      name: interface.name,
      sys_name: interface.sys_name,
      ip: interface.ip
    }
  end
end

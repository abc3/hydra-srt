defmodule HydraSrt.Interfaces do
  @moduledoc false

  alias HydraSrt.Db
  alias HydraSrt.SystemInterfaces

  @spec list() :: {:ok, [map()]} | {:error, term()}
  def list, do: Db.get_all_interfaces()

  @spec get(String.t()) :: {:ok, map()} | {:error, term()}
  def get(interface_id) when is_binary(interface_id), do: Db.get_interface(interface_id)

  @spec create(map()) :: {:ok, map()} | {:error, term()}
  def create(interface_params) when is_map(interface_params),
    do: Db.create_interface(interface_params)

  @spec update(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update(interface_id, interface_params)
      when is_binary(interface_id) and is_map(interface_params) do
    Db.update_interface(interface_id, interface_params)
  end

  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(interface_id) when is_binary(interface_id), do: Db.delete_interface(interface_id)

  @spec list_system() :: {:ok, [map()]} | {:error, String.t()}
  def list_system do
    case SystemInterfaces.discover() do
      {:ok, interfaces} ->
        {:ok, interfaces}

      {:error, reason} ->
        {:error, "Failed to read system interfaces: #{inspect(reason)}"}
    end
  end

  @spec get_system(String.t()) :: {:ok, map()} | {:error, String.t()}
  def get_system(sys_name) when is_binary(sys_name) do
    with {:ok, interfaces} <- list_system() do
      case Enum.find(interfaces, &(&1["sys_name"] == sys_name)) do
        nil -> {:error, "System interface not found: #{sys_name}"}
        interface -> {:ok, interface}
      end
    end
  end

  @spec system_raw() :: {:ok, String.t()} | {:error, String.t()}
  def system_raw do
    case SystemInterfaces.discover_raw() do
      {:ok, raw} -> {:ok, raw}
      {:error, reason} -> {:error, "Failed to read raw ifconfig: #{inspect(reason)}"}
    end
  end
end

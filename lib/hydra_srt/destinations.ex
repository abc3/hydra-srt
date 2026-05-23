defmodule HydraSrt.Destinations do
  @moduledoc false

  alias HydraSrt.Db

  @spec list(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list(route_id) when is_binary(route_id), do: Db.get_all_destinations(route_id)

  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(route_id, destination_id)
      when is_binary(route_id) and is_binary(destination_id),
      do: Db.get_destination(route_id, destination_id)

  @spec create(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def create(route_id, destination_params)
      when is_binary(route_id) and is_map(destination_params),
      do: Db.create_destination(route_id, destination_params)

  @spec update(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update(route_id, destination_id, destination_params)
      when is_binary(route_id) and is_binary(destination_id) and is_map(destination_params) do
    Db.update_destination(route_id, destination_id, destination_params)
  end

  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(route_id, destination_id)
      when is_binary(route_id) and is_binary(destination_id),
      do: Db.del_destination(route_id, destination_id)
end

defmodule HydraSrt.Sources do
  @moduledoc false

  alias HydraSrt.Db
  alias HydraSrt.Routes

  @spec list(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list(route_id) when is_binary(route_id), do: Db.get_all_sources(route_id)

  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(route_id, source_id)
      when is_binary(route_id) and is_binary(source_id),
      do: Db.get_source(route_id, source_id)

  @spec create(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def create(route_id, source_params)
      when is_binary(route_id) and is_map(source_params),
      do: Db.create_source(route_id, source_params)

  @spec update(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update(route_id, source_id, source_params)
      when is_binary(route_id) and is_binary(source_id) and is_map(source_params) do
    Db.update_source(route_id, source_id, source_params)
  end

  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(route_id, source_id)
      when is_binary(route_id) and is_binary(source_id),
      do: Db.del_source(route_id, source_id)

  @spec reorder(String.t(), [String.t()]) :: {:ok, [map()]} | {:error, term()}
  def reorder(route_id, source_ids)
      when is_binary(route_id) and is_list(source_ids),
      do: Db.reorder_sources(route_id, source_ids)

  @spec test(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def test(route_id, source_id, opts \\ [])
      when is_binary(route_id) and is_binary(source_id) do
    with {:ok, source} <- Db.get_source(route_id, source_id) do
      Routes.test_source_config(source, opts)
    end
  end
end

defmodule HydraSrt.Tags do
  @moduledoc false

  alias HydraSrt.Db

  @spec list() :: [map()]
  def list do
    Db.list_tags()
    |> Enum.map(&serialize/1)
  end

  @spec serialize(%HydraSrt.Api.Tag{}) :: map()
  def serialize(tag) do
    %{
      id: tag.id,
      name: tag.name,
      inserted_at: tag.inserted_at,
      updated_at: tag.updated_at
    }
  end

  @spec create(map()) :: {:ok, map()} | {:error, term()}
  def create(tag_params) when is_map(tag_params) do
    case Db.create_tag(tag_params) do
      {:ok, tag} -> {:ok, serialize(tag)}
      error -> error
    end
  end

  @spec update(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update(id, tag_params) when is_binary(id) and is_map(tag_params) do
    case Db.update_tag(id, tag_params) do
      {:ok, tag} -> {:ok, serialize(tag)}
      error -> error
    end
  end

  @spec delete(String.t()) :: {:ok, map()} | {:error, term()}
  def delete(id) when is_binary(id) do
    case Db.delete_tag(id) do
      {:ok, tag} -> {:ok, serialize(tag)}
      error -> error
    end
  end
end

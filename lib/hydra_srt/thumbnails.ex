defmodule HydraSrt.Thumbnails do
  @moduledoc false
  use GenServer

  @table __MODULE__
  @default_content_type "image/jpeg"

  @type thumbnail :: %{
          route_id: String.t(),
          source_id: String.t(),
          bytes: binary(),
          content_type: String.t(),
          updated_at: DateTime.t(),
          version: integer()
        }

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    {:ok, state}
  end

  @spec put(String.t(), String.t(), binary(), keyword()) :: {:ok, map()}
  def put(route_id, source_id, bytes, opts \\ [])
      when is_binary(route_id) and is_binary(source_id) and is_binary(bytes) do
    content_type = Keyword.get(opts, :content_type, @default_content_type)
    updated_at = Keyword.get(opts, :updated_at, DateTime.utc_now(:microsecond))
    version = System.unique_integer([:positive, :monotonic])

    thumbnail = %{
      route_id: route_id,
      source_id: source_id,
      bytes: bytes,
      content_type: content_type,
      updated_at: updated_at,
      version: version
    }

    true = :ets.insert(@table, {{route_id, source_id}, thumbnail})
    {:ok, metadata(thumbnail)}
  end

  @spec put_base64(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :invalid_thumbnail}
  def put_base64(route_id, source_id, data_base64, opts \\ [])
      when is_binary(data_base64) do
    case Base.decode64(data_base64) do
      {:ok, bytes} -> put(route_id, source_id, bytes, opts)
      :error -> {:error, :invalid_thumbnail}
    end
  end

  @spec get(String.t(), String.t()) :: {:ok, thumbnail()} | {:error, :not_found}
  def get(route_id, source_id) when is_binary(route_id) and is_binary(source_id) do
    case :ets.lookup(@table, {route_id, source_id}) do
      [{{^route_id, ^source_id}, thumbnail}] -> {:ok, thumbnail}
      _ -> {:error, :not_found}
    end
  end

  @spec metadata(map()) :: map()
  def metadata(thumbnail) when is_map(thumbnail) do
    %{
      route_id: thumbnail.route_id,
      source_id: thumbnail.source_id,
      content_type: thumbnail.content_type,
      updated_at: DateTime.to_iso8601(thumbnail.updated_at),
      version: thumbnail.version
    }
  end
end

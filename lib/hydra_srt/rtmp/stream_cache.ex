defmodule HydraSrt.Rtmp.StreamCache do
  @moduledoc """
  Caches RTMP stream bootstrap data (metadata and codec sequence headers) per path.
  Play clients that connect after publishing starts receive cached headers first.
  """

  @table :hydra_rtmp_stream_cache

  @type entry :: %{
          optional(:metadata) => {map(), non_neg_integer()},
          optional(:audio_header) => {binary(), non_neg_integer()},
          optional(:video_header) => {binary(), non_neg_integer()}
        }

  @spec init() :: :ok
  def init do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        :ok
    end

    :ok
  end

  @spec record_metadata(String.t(), map(), non_neg_integer()) :: :ok
  def record_metadata(path, metadata, timestamp)
      when is_binary(path) and path != "" and is_map(metadata) do
    update(path, :metadata, {metadata, timestamp})
  end

  @spec record_media(String.t(), 8 | 9, binary(), non_neg_integer()) :: :ok
  def record_media(path, type, data, timestamp)
      when is_binary(path) and path != "" and is_binary(data) do
    if sequence_header?(type, data) do
      update(path, header_key(type), {data, timestamp})
    end

    :ok
  end

  @spec get(String.t()) :: entry() | nil
  def get(path) when is_binary(path) do
    init()

    case :ets.lookup(@table, path) do
      [{^path, entry}] -> entry
      [] -> nil
    end
  end

  @spec sequence_header?(8 | 9, binary()) :: boolean()
  def sequence_header?(8, data), do: aac_sequence_header?(data)
  def sequence_header?(9, data), do: avc_sequence_header?(data)

  @spec aac_sequence_header?(binary()) :: boolean()
  def aac_sequence_header?(<<10::4, _sound_info::4, 0::8, _::binary>>), do: true
  def aac_sequence_header?(_data), do: false

  @spec avc_sequence_header?(binary()) :: boolean()
  def avc_sequence_header?(<<_frame_type::4, 7::4, 0::8, _::binary>>), do: true
  def avc_sequence_header?(_data), do: false

  @spec header_key(8 | 9) :: :audio_header | :video_header
  def header_key(8), do: :audio_header
  def header_key(9), do: :video_header

  @spec update(String.t(), atom(), term()) :: :ok
  def update(path, key, value) do
    init()
    entry = Map.put(get(path) || %{}, key, value)
    :ets.insert(@table, {path, entry})
    :ok
  end
end

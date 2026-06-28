defmodule HydraSrt.Rtmp.StreamCache do
  @moduledoc """
  Caches RTMP stream bootstrap data (metadata and codec sequence headers) per path.

  Play clients that connect after publishing starts receive cached headers first
  (`send_cached_bootstrap/1` in `HydraSrt.Rtmp.Session`).

  Backed by a dedicated Cachex instance (`HydraSrt.RtmpCache`) with a TTL safety net,
  so stale headers auto-expire even when an explicit `clear/1` on publisher
  disconnect is missed (e.g. process crash). Explicit `clear/1` on publish start and
  publisher disconnect remains the primary invalidation path.

  The TTL is refreshed on every incoming media frame (sequence header or not) so a
  healthy, long-running publish never ages out its bootstrap data mid-stream; once the
  publisher stops sending, the TTL lapses and the safety net reclaims the entry.
  """

  @cache HydraSrt.RtmpCache

  @type header_key :: :audio_header | :video_header
  @type record_status :: :new | :changed | :same | :ignored

  @type entry :: %{
          optional(:metadata) => {map(), non_neg_integer()},
          optional(:audio_header) => {binary(), non_neg_integer()},
          optional(:video_header) => {binary(), non_neg_integer()}
        }

  @spec cache() :: atom()
  def cache, do: @cache

  @spec bootstrap_ttl_ms() :: non_neg_integer()
  def bootstrap_ttl_ms do
    Application.get_env(:hydra_srt, :rtmp_bootstrap_ttl_ms, :timer.seconds(30))
  end

  @spec record_metadata(String.t(), map(), non_neg_integer()) :: :ok
  def record_metadata(path, metadata, timestamp)
      when is_binary(path) and path != "" and is_map(metadata) do
    update(path, :metadata, {metadata, timestamp})
  end

  @spec record_media(String.t(), 8 | 9, binary(), non_neg_integer()) :: record_status()
  def record_media(path, type, data, timestamp)
      when is_binary(path) and path != "" and is_binary(data) do
    if sequence_header?(type, data) do
      key = header_key(type)

      case header_bytes(path, key) do
        nil ->
          update(path, key, {data, timestamp})
          :new

        ^data ->
          # Identical header, but the publish is still live — refresh the TTL so the
          # entry does not age out while the stream keeps flowing.
          touch_ttl(path)
          :same

        _changed ->
          update(path, key, {data, timestamp})
          :changed
      end
    else
      # Non-sequence-header media frames carry no bootstrap data, but they prove the
      # publisher is still active, so refresh the TTL and keep the cached headers alive.
      touch_ttl(path)
      :ignored
    end
  end

  @spec get(String.t()) :: entry() | nil
  def get(path) when is_binary(path) do
    case Cachex.get(@cache, path) do
      {:ok, entry} when is_map(entry) -> entry
      _ -> nil
    end
  end

  @spec clear(String.t()) :: :ok
  def clear(path) when is_binary(path) do
    _ = Cachex.del(@cache, path)
    :ok
  end

  @spec clear_header(String.t(), header_key()) :: :ok
  def clear_header(path, key) when is_binary(path) and key in [:audio_header, :video_header] do
    case get(path) do
      nil -> :ok
      entry -> put(path, Map.delete(entry, key))
    end
  end

  # FLV video codec ids carried in the low nibble of the first video-tag byte.
  # 7 = AVC (H.264), 12 = HEVC (H.265). HEVC publishers — including FFmpeg with the
  # Enhanced-RTMP signaling — use codec id 12, so both must be recognized or their
  # sequence headers are never cached and `:check_codecs` kills a healthy stream.
  @avc_codec_id 7
  @hevc_codec_id 12

  @spec sequence_header?(8 | 9, binary()) :: boolean()
  def sequence_header?(8, data), do: aac_sequence_header?(data)
  def sequence_header?(9, data), do: video_sequence_header?(data)

  @spec aac_sequence_header?(binary()) :: boolean()
  def aac_sequence_header?(<<10::4, _sound_info::4, 0::8, _::binary>>), do: true
  def aac_sequence_header?(_data), do: false

  @spec video_sequence_header?(binary()) :: boolean()
  # Legacy AVC (codec id 7): FrameType | 7, then AVCPacketType 0 (sequence header).
  def video_sequence_header?(<<_frame_type::4, @avc_codec_id::4, 0::8, _::binary>>), do: true
  # Legacy HEVC (codec id 12): FrameType | 12, then packet type 0 (sequence header).
  def video_sequence_header?(<<_frame_type::4, @hevc_codec_id::4, 0::8, _::binary>>), do: true
  # Enhanced RTMP: the high bit of the first byte is set, the next 3 bits are the
  # PacketType (0 = Sequence Start, the only one carrying a decoder config record)
  # and the low nibble is the codec id. Match HEVC sequence starts here.
  def video_sequence_header?(<<1::1, 0::3, @hevc_codec_id::4, _::binary>>), do: true
  def video_sequence_header?(_data), do: false

  @spec header_key(8 | 9) :: header_key()
  def header_key(8), do: :audio_header
  def header_key(9), do: :video_header

  @spec update(String.t(), atom(), term()) :: :ok
  defp update(path, key, value) do
    entry = Map.put(get(path) || %{}, key, value)
    put(path, entry)
  end

  @spec put(String.t(), entry()) :: :ok
  defp put(path, entry) do
    _ = Cachex.put(@cache, path, entry, ttl: bootstrap_ttl_ms())
    :ok
  end

  @spec touch_ttl(String.t()) :: :ok
  defp touch_ttl(path) do
    # Refresh the entry's TTL deadline without rewriting its value. `Cachex.touch/2`
    # only updates the touched_at timestamp, not the deadline, so we use `expire/3`
    # to push the expiration out by the full bootstrap TTL again. A no-op (returns
    # `{:ok, false}`) when no entry exists yet, e.g. raw media arriving before any
    # sequence header has been cached.
    _ = Cachex.expire(@cache, path, bootstrap_ttl_ms())
    :ok
  end

  @spec header_bytes(String.t(), header_key()) :: binary() | nil
  defp header_bytes(path, key) do
    case get(path) do
      %{^key => {data, _timestamp}} when is_binary(data) -> data
      _ -> nil
    end
  end
end

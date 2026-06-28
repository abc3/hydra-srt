defmodule HydraSrt.Rtmp.StreamCacheTest do
  use ExUnit.Case, async: true

  alias HydraSrt.Rtmp.StreamCache

  defp unique_path, do: "/test/#{System.unique_integer([:positive])}"

  defp aac_sequence_header do
    <<0xAF, 0x00, 0x12, 0x10>>
  end

  defp aac_raw_chunk do
    <<0xAF, 0x01, 0xFF, 0xFF>>
  end

  defp avc_sequence_header do
    <<0x17, 0x00, 0x00, 0x00, 0x01, 0x64, 0x00, 0x1F>>
  end

  defp avc_nalu_chunk do
    <<0x27, 0x01, 0x00, 0x00, 0x05>>
  end

  # Legacy HEVC sequence header: keyframe (frame type 1) | codec id 12, packet type 0.
  defp hevc_sequence_header do
    <<0x1C, 0x00, 0x01, 0x60, 0x00, 0x00, 0x00, 0x00>>
  end

  # HEVC NALU (coded frame) chunk: codec id 12, packet type 1 — not a seq header.
  defp hevc_nalu_chunk do
    <<0x2C, 0x01, 0x00, 0x00, 0x05>>
  end

  # Enhanced-RTMP HEVC sequence start: high bit set, PacketType 0, codec id 12 (0x8C),
  # followed by an HEVCDecoderConfigurationRecord.
  defp hevc_enhanced_sequence_header do
    <<0x8C, 0x01, 0x60, 0x00, 0x00, 0x00, 0x00>>
  end

  describe "record_media/4 sequence header detection" do
    test "detects AAC sequence header and stores audio_header" do
      path = unique_path()
      data = aac_sequence_header()
      assert StreamCache.record_media(path, 8, data, 100) == :new

      assert %{audio_header: {^data, 100}} = StreamCache.get(path)
    end

    test "detects AVC sequence header and stores video_header" do
      path = unique_path()
      data = avc_sequence_header()
      assert StreamCache.record_media(path, 9, data, 200) == :new

      assert %{video_header: {^data, 200}} = StreamCache.get(path)
    end

    test "detects legacy HEVC sequence header (codec id 12) and stores video_header" do
      path = unique_path()
      data = hevc_sequence_header()
      assert StreamCache.record_media(path, 9, data, 200) == :new

      assert %{video_header: {^data, 200}} = StreamCache.get(path)
    end

    test "detects enhanced-RTMP HEVC sequence start and stores video_header" do
      path = unique_path()
      data = hevc_enhanced_sequence_header()
      assert StreamCache.record_media(path, 9, data, 200) == :new

      assert %{video_header: {^data, 200}} = StreamCache.get(path)
    end

    test "ignores non-sequence-header audio chunks" do
      path = unique_path()
      assert StreamCache.record_media(path, 8, aac_raw_chunk(), 300) == :ignored
      assert StreamCache.get(path) == nil
    end

    test "ignores non-sequence-header video chunks" do
      path = unique_path()
      assert StreamCache.record_media(path, 9, avc_nalu_chunk(), 400) == :ignored
      assert StreamCache.get(path) == nil
    end

    test "ignores non-sequence-header HEVC coded-frame chunks" do
      path = unique_path()
      assert StreamCache.record_media(path, 9, hevc_nalu_chunk(), 400) == :ignored
      assert StreamCache.get(path) == nil
    end

    test "returns :same when identical sequence header is re-recorded" do
      path = unique_path()
      assert :new = StreamCache.record_media(path, 9, avc_sequence_header(), 500)
      assert :same = StreamCache.record_media(path, 9, avc_sequence_header(), 600)
    end

    test "non-sequence-header media refreshes the entry TTL so it does not age out mid-publish" do
      path = unique_path()
      :new = StreamCache.record_media(path, 9, avc_sequence_header(), 1)
      assert StreamCache.get(path) != nil

      {:ok, ttl_after_put} = Cachex.ttl(StreamCache.cache(), path)
      Process.sleep(60)
      {:ok, ttl_after_sleep} = Cachex.ttl(StreamCache.cache(), path)
      assert ttl_after_sleep < ttl_after_put

      # A raw media frame carries no bootstrap data but proves the publisher is live,
      # so it must refresh the TTL without disturbing the cached header.
      :ignored = StreamCache.record_media(path, 9, avc_nalu_chunk(), 2)
      {:ok, ttl_after_touch} = Cachex.ttl(StreamCache.cache(), path)
      assert ttl_after_touch > ttl_after_sleep

      assert %{video_header: {_, 1}} = StreamCache.get(path)
    end

    test "an identical sequence header (:same) refreshes the entry TTL" do
      path = unique_path()
      :new = StreamCache.record_media(path, 9, avc_sequence_header(), 1)

      Process.sleep(60)
      {:ok, ttl_before} = Cachex.ttl(StreamCache.cache(), path)

      :same = StreamCache.record_media(path, 9, avc_sequence_header(), 2)
      {:ok, ttl_after} = Cachex.ttl(StreamCache.cache(), path)
      assert ttl_after > ttl_before
    end

    test "returns :changed when a different sequence header replaces the cached one" do
      path = unique_path()
      first = avc_sequence_header()
      assert :new = StreamCache.record_media(path, 9, first, 700)

      second = <<0x17, 0x00, 0x00, 0x00, 0x01, 0x77, 0x00, 0x28>>
      assert :changed = StreamCache.record_media(path, 9, second, 800)

      assert %{video_header: {^second, 800}} = StreamCache.get(path)
    end
  end

  describe "record_metadata/3" do
    test "stores metadata and overwrites on subsequent calls" do
      path = unique_path()
      :ok = StreamCache.record_metadata(path, %{"width" => 1280}, 100)
      assert %{metadata: {%{"width" => 1280}, 100}} = StreamCache.get(path)

      :ok = StreamCache.record_metadata(path, %{"width" => 1920}, 200)
      assert %{metadata: {%{"width" => 1920}, 200}} = StreamCache.get(path)
    end
  end

  describe "get/1" do
    test "returns nil for unknown path" do
      assert StreamCache.get(unique_path()) == nil
    end

    test "accumulates metadata and headers in one entry" do
      path = unique_path()
      :ok = StreamCache.record_metadata(path, %{"width" => 1280}, 1)
      :new = StreamCache.record_media(path, 8, aac_sequence_header(), 2)
      :new = StreamCache.record_media(path, 9, avc_sequence_header(), 3)

      entry = StreamCache.get(path)
      assert entry[:metadata] == {%{"width" => 1280}, 1}
      assert match?(%{audio_header: {_, 2}}, entry)
      assert match?(%{video_header: {_, 3}}, entry)
    end
  end

  describe "clear/1 and clear_header/2" do
    test "clear/1 removes the whole entry" do
      path = unique_path()
      :new = StreamCache.record_media(path, 9, avc_sequence_header(), 1)
      assert StreamCache.get(path) != nil

      :ok = StreamCache.clear(path)
      assert StreamCache.get(path) == nil
    end

    test "clear_header/2 removes only the targeted header" do
      path = unique_path()
      :new = StreamCache.record_media(path, 8, aac_sequence_header(), 1)
      :new = StreamCache.record_media(path, 9, avc_sequence_header(), 2)

      :ok = StreamCache.clear_header(path, :video_header)

      entry = StreamCache.get(path)
      assert match?(%{audio_header: {_, 1}}, entry)
      refute Map.has_key?(entry, :video_header)
    end

    test "clear_header/2 is a no-op when no entry exists" do
      path = unique_path()
      assert :ok = StreamCache.clear_header(path, :audio_header)
      assert StreamCache.get(path) == nil
    end
  end

  describe "sequence_header?/2" do
    test "classifies audio and video payloads" do
      assert StreamCache.sequence_header?(8, aac_sequence_header())
      refute StreamCache.sequence_header?(8, aac_raw_chunk())

      assert StreamCache.sequence_header?(9, avc_sequence_header())
      refute StreamCache.sequence_header?(9, avc_nalu_chunk())

      assert StreamCache.sequence_header?(9, hevc_sequence_header())
      assert StreamCache.sequence_header?(9, hevc_enhanced_sequence_header())
      refute StreamCache.sequence_header?(9, hevc_nalu_chunk())
    end
  end
end

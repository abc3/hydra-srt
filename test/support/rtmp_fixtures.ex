defmodule HydraSrt.TestSupport.RtmpFixtures do
  @moduledoc """
  Helpers for building RTMP messages and sessions in unit tests.
  """

  alias ExRTMP.Message
  alias ExRTMP.Message.Command.NetStream.{FCPublish, Publish}
  alias HydraSrt.Rtmp.Session

  @doc """
  Builds a connected `%Session{}` ready for `Publish`/`Play` commands.
  `publisher_pid` defaults to `self()`.
  """
  def connected_session(attrs \\ %{}) do
    defaults = %{
      phase: :connected,
      stream_id: 1,
      app: "live",
      peer: {{127, 0, 0, 1}, 50_000},
      publisher_pid: self()
    }

    struct(Session, Map.merge(defaults, attrs))
  end

  @doc """
  Builds a type-20 command message carrying a `Publish` command for `name`.
  """
  def publish_message(name, stream_id \\ 1) do
    Message.new(Publish.new(name, "live"), type: 20, timestamp: 0, stream_id: stream_id)
  end

  @doc """
  Builds a type-20 command message carrying an `FCPublish` command for `name`.
  """
  def fcpublish_message(name, transaction_id \\ 0.0) do
    Message.new(FCPublish.new(transaction_id, name), type: 20, timestamp: 0, stream_id: 0)
  end

  @doc """
  A valid AAC sequence header (AAC-LC, 44.1kHz, stereo).
  """
  def aac_sequence_header, do: <<0xAF, 0x00, 0x12, 0x10>>

  @doc """
  Builds a type-18 onMetaData message carrying `metadata`.
  """
  def metadata_message(metadata, stream_id \\ 1) do
    ExRTMP.Message.metadata(metadata, stream_id)
  end

  @doc """
  A valid AVC sequence header (keyframe, baseline profile).
  """
  def avc_sequence_header, do: <<0x17, 0x00, 0x00, 0x00, 0x01, 0x64, 0x00, 0x1F>>

  @doc """
  A non-sequence-header AAC raw audio chunk.
  """
  def aac_raw_chunk, do: <<0xAF, 0x01, 0xFF, 0xFF>>

  @doc """
  A non-sequence-header AVC NALU video chunk (inter frame).
  """
  def avc_nalu_chunk, do: <<0x27, 0x01, 0x00, 0x00, 0x05>>
end

defmodule HydraSrt.E2EHelpersRtmpTest do
  use ExUnit.Case, async: true

  alias HydraSrt.TestSupport.E2EHelpers

  test "rtmp_play_url normalizes path and uses configured port" do
    previous = Application.get_env(:hydra_srt, :rtmp_port)
    Application.put_env(:hydra_srt, :rtmp_port, 1937)

    on_exit(fn ->
      Application.put_env(:hydra_srt, :rtmp_port, previous)
    end)

    assert E2EHelpers.rtmp_play_url("/live/stream") ==
             "rtmp://127.0.0.1:1937/live/stream"

    assert E2EHelpers.rtmp_play_url("live/stream") ==
             "rtmp://127.0.0.1:1937/live/stream"
  end

  test "rtmp_streams_include_av? accepts h264 and aac streams" do
    streams = [
      %{"codec_type" => "video", "codec_name" => "h264"},
      %{"codec_type" => "audio", "codec_name" => "aac"}
    ]

    assert E2EHelpers.rtmp_streams_include_av?(streams)
    refute E2EHelpers.rtmp_streams_include_av?([Enum.at(streams, 0)])
  end
end

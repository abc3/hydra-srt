defmodule HydraSrt.TestSupport.YoutubeHarnessTest do
  use ExUnit.Case, async: false

  alias HydraSrt.TestSupport.FakeYtDlp
  alias HydraSrt.TestSupport.HlsGenerator
  alias HydraSrt.TestSupport.HlsServer

  test "fake yt-dlp success and failure fixtures use the pinned output shape" do
    url = "http://127.0.0.1:4567/playlist.m3u8"

    for variant <- [:live, :vod, :expiring] do
      env =
        [{"YOUTUBE_TEST_URL", url}] ++
          if(variant == :expiring,
            do: [{"YOUTUBE_TEST_EXPIRE", Integer.to_string(System.system_time(:second) + 10)}],
            else: []
          )

      {output, 0} = System.cmd(FakeYtDlp.path(variant), [], env: env)

      [resolved_url, metadata] = String.split(String.trim(output), "\n")
      assert String.starts_with?(resolved_url, url)
      assert variant != :expiring or resolved_url =~ "expire="
      # Real yt-dlp does not expand escapes in --print, so the pinned shape is a
      # single JSON object rather than tab-separated fields.
      assert {:ok, decoded} = Jason.decode(metadata)
      assert decoded["id"] == "fixture"
      assert is_boolean(decoded["is_live"])
      assert decoded["is_live"] == (variant != :vod)
      assert decoded["title"] == "Hydra HLS fixture"
    end

    {output, 1} =
      System.cmd(FakeYtDlp.path(:bot_check), [],
        env: [{"YOUTUBE_TEST_URL", url}],
        stderr_to_stdout: true
      )

    assert output =~ "Sign in to confirm you're not a bot"
  end

  test "HTTP fixture serves files and exposes explicit failure controls" do
    root =
      Path.join(System.tmp_dir!(), "hydra_hls_server_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "playlist.m3u8"),
      "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nsegment_000001.ts\n"
    )

    File.write!(Path.join(root, "segment_000001.ts"), "fixture")

    {:ok, server} = HlsServer.start(root)

    on_exit(fn ->
      HlsServer.stop(server)
      File.rm_rf!(root)
    end)

    assert {200, playlist} = http_get(HlsServer.playlist_url(server))
    assert playlist =~ "#EXT-X-VERSION:3"
    assert playlist =~ "#EXT-X-TARGETDURATION:5"

    :ok = HlsServer.set_behavior(server, :segments_403)
    assert {403, _body} = http_get(HlsServer.url(server, "segment_000001.ts"))

    :ok = HlsServer.set_behavior(server, :playlist_404)
    assert {404, _body} = http_get(HlsServer.playlist_url(server))

    :ok = HlsServer.set_behavior(server, :discontinuous)
    assert {200, discontinuous} = http_get(HlsServer.playlist_url(server))
    assert discontinuous =~ "#EXT-X-DISCONTINUITY"
  end

  @tag :e2e
  test "ffmpeg generator makes live and VOD MPEG-TS playlists" do
    assert {:ok, live} =
             HlsGenerator.start(
               mode: :live,
               width: 320,
               height: 240,
               fps: 15,
               segment_duration_sec: 1
             )

    on_exit(fn -> HlsGenerator.stop(live) end)
    assert {:ok, live_playlist} = HlsGenerator.read_playlist(live)
    assert live_playlist =~ "#EXTM3U"
    refute live_playlist =~ "#EXT-X-ENDLIST"
    assert File.exists?(Path.join([HlsGenerator.directory(live), "file", "seg_000000.ts"]))

    HlsGenerator.stop(live)

    assert {:ok, vod} =
             HlsGenerator.start(
               mode: :vod,
               duration_sec: 1,
               realtime: false,
               width: 320,
               height: 240,
               fps: 15,
               segment_duration_sec: 1
             )

    on_exit(fn -> HlsGenerator.stop(vod) end)
    assert {:ok, vod_playlist} = HlsGenerator.read_playlist(vod)
    assert vod_playlist =~ "#EXT-X-ENDLIST"
  end

  @spec http_get(String.t()) :: {pos_integer(), String.t()}
  def http_get(url) do
    :inets.start()

    case :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, body}} -> {status, body}
      {:ok, {{_, status}, _headers, body}} -> {status, body}
    end
  end
end

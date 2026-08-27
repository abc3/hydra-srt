defmodule HydraSrt.YoutubeTest do
  use ExUnit.Case, async: false

  alias HydraSrt.TestSupport.FakeYtDlp
  alias HydraSrt.Youtube
  alias HydraSrt.Youtube.Cache
  alias HydraSrt.Youtube.Resolver
  alias HydraSrt.Youtube.ResolverYtDlp
  alias HydraSrt.Youtube.Url

  @watch_url "https://www.youtube.com/watch?v=fO9e9jnhYK8"

  setup do
    Youtube.invalidate(@watch_url)
    :ok
  end

  test "canonicalizes supported watch and short URLs without accepting lookalike hosts" do
    assert {:ok, "https://www.youtube.com/watch?v=fO9e9jnhYK8"} =
             Url.canonicalize("https://m.youtube.com/watch?v=fO9e9jnhYK8&list=ignored")

    assert {:ok, "https://www.youtube.com/watch?v=fO9e9jnhYK8"} =
             Url.canonicalize("https://youtu.be/fO9e9jnhYK8")

    assert {:error, :invalid_url} =
             Url.canonicalize("https://youtube.com.evil.example/watch?v=fO9e9jnhYK8")

    assert {:error, :invalid_url} = Url.canonicalize("https://youtube.com/watch?v=short")
  end

  test "resolver uses the fake executable and keeps bearer URI out of media info" do
    url = "http://127.0.0.1:4567/playlist.m3u8?expire=9999999999"

    FakeYtDlp.with_variant(:live, url, fn ->
      assert {:ok, resolved} = Youtube.resolve(@watch_url, timeout_ms: 2_000)
      assert resolved.uri == url
      refute inspect(resolved.media_info) =~ url
      assert resolved.live
      assert resolved.format_id == "96"
    end)
  end

  test "surfaces a changed format when the selected itag is unavailable" do
    url = "http://127.0.0.1:4567/playlist.m3u8"

    FakeYtDlp.with_variant(:live, url, [format_id: "91"], fn ->
      assert {:ok, resolved} = Youtube.resolve(@watch_url, format_id: "96")
      assert resolved.format_id == "91"
      assert resolved.media_info["format_fallback"]
    end)
  end

  test "resolve floor blocks a different policy before spawning yt-dlp again" do
    url = "http://127.0.0.1:4567/playlist.m3u8"

    FakeYtDlp.with_variant(:live, url, fn ->
      assert {:ok, _resolved} = Youtube.resolve(@watch_url, quality_policy: "best[height<=720]")

      FakeYtDlp.configure!(:bot_check, url)

      assert {:error, :resolve_rate_limited} =
               Youtube.resolve(@watch_url, quality_policy: "best[height<=1080]")
    end)
  end

  test "captured resolver failures have distinct actionable reasons" do
    assert ResolverYtDlp.classify_error(
             File.read!("test/support/fixtures/captured_bot_challenge.stderr")
           ) ==
             :bot_reload_challenge

    fixture_reasons = [
      {FakeYtDlp.path(:bot_check), :bot_check_challenge},
      {FakeYtDlp.path(:private), :private_video},
      {FakeYtDlp.path(:not_live), :not_live},
      {FakeYtDlp.path(:geo_blocked), :geo_blocked},
      {FakeYtDlp.path(:unavailable), :video_unavailable},
      {FakeYtDlp.path(:challenge), :bot_reload_challenge}
    ]

    for {fixture, reason} <- fixture_reasons do
      {output, 1} = System.cmd(fixture, [], stderr_to_stdout: true)
      assert ResolverYtDlp.classify_error(output) == reason
    end

    assert Youtube.error_message(:bot_check_challenge) =~ "cookies"
    assert Youtube.error_message(:media_access_forbidden) =~ "403"
  end

  test "media 403 captured signature is actionable" do
    output = File.read!("test/support/fixtures/captured_media_403.stderr")
    assert output =~ "Segment"
    assert ResolverYtDlp.classify_error(output) == :media_access_forbidden
    assert Youtube.error_message(:media_access_forbidden) =~ "media segments"
  end

  test "cache derives a safety-margin TTL and has a fixed fallback" do
    now = System.system_time(:second)

    assert Cache.ttl_ms("https://video.example/playlist.m3u8?expire=#{now + 3_600}", now) ==
             3_000_000

    assert Cache.ttl_ms("https://video.example/playlist.m3u8", now) == :timer.minutes(30)
    assert Cache.expires_at("https://video.example/playlist.m3u8?x=1&expire=123") == 123
    assert Cache.expires_at("https://video.example/playlist.m3u8") == nil
  end

  test "fake yt-dlp errors are negative cached" do
    FakeYtDlp.with_variant(:bot_check, "http://127.0.0.1:4567/playlist.m3u8", fn ->
      assert {:error, :bot_check_challenge} = Youtube.resolve(@watch_url, timeout_ms: 2_000)
      assert {:error, :bot_check_challenge} = Youtube.resolve(@watch_url, timeout_ms: 2_000)
    end)
  end

  test "timeout kills the fake yt-dlp process" do
    FakeYtDlp.with_variant(:hang, "http://127.0.0.1:4567/playlist.m3u8", fn ->
      started = System.monotonic_time(:millisecond)
      assert {:error, :resolver_timeout} = Resolver.resolve(@watch_url, timeout_ms: 100)
      assert System.monotonic_time(:millisecond) - started < 2_000
    end)
  end
end

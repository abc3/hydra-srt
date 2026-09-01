defmodule HydraSrt.YoutubeTest do
  use ExUnit.Case, async: false

  alias HydraSrt.TestSupport.FakeYtDlp
  alias HydraSrt.Youtube
  alias HydraSrt.Youtube.Cache
  alias HydraSrt.Youtube.Resolver
  alias HydraSrt.Youtube.ResolverYtDlp
  alias HydraSrt.Youtube.Url

  @watch_url "https://www.youtube.com/watch?v=fO9e9jnhYK8"

  defmodule UnsupportedResolver do
    @behaviour HydraSrt.Youtube.Resolver

    @spec resolve(String.t(), keyword()) :: HydraSrt.Youtube.Resolver.result()
    def resolve(_url, _opts), do: {:error, :unsupported_format}
  end

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

  test "inspect builds a variant list from the resolved media" do
    FakeYtDlp.with_variant(:live, "http://127.0.0.1:4567/playlist.m3u8", fn ->
      assert {:ok, inspected} = Youtube.inspect(@watch_url)

      assert [%{format_id: "96", label: "format 96", has_video: true, has_audio: true}] =
               inspected.variants

      assert inspected.live
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

  test "keeps an unsupported format error when no policy fallback is available" do
    previous = Application.get_env(:hydra_srt, :youtube, :__unset__)
    Application.put_env(:hydra_srt, :youtube, resolver: UnsupportedResolver)

    on_exit(fn ->
      case previous do
        :__unset__ -> Application.delete_env(:hydra_srt, :youtube)
        value -> Application.put_env(:hydra_srt, :youtube, value)
      end
    end)

    assert {:error, :unsupported_format} = Youtube.resolve_uncached(@watch_url, [])
    assert {:error, :unsupported_format} = Youtube.resolve_uncached(@watch_url, format_id: "96")
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

  test "maps every resolver reason to a non-empty client message" do
    reasons = [
      :invalid_url,
      :bot_check_challenge,
      :resolver_not_found,
      :resolver_timeout,
      :resolver_failed,
      :invalid_output,
      :unsupported_format,
      :cookies_unreadable,
      :private_video,
      :not_live,
      :geo_blocked,
      :video_unavailable,
      :bot_reload_challenge,
      :resolver_outdated,
      :media_access_forbidden,
      :resolve_rate_limited,
      :not_implemented
    ]

    for reason <- reasons do
      assert is_binary(Youtube.error_message(reason))
      refute Youtube.error_message(reason) == ""
    end
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

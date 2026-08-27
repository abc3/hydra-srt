defmodule HydraSrtWeb.YoutubeControllerTest do
  use HydraSrtWeb.ConnCase, async: false

  alias HydraSrt.TestSupport.FakeYtDlp

  @url "https://www.youtube.com/watch?v=fO9e9jnhYK8"

  setup %{conn: conn} do
    # The resolver cache is global, so one test's result would otherwise answer
    # the next test's request for the same video.
    :ok = HydraSrt.Youtube.invalidate(@url)

    {:ok, conn: conn |> put_req_header("accept", "application/json") |> log_in_user()}
  end

  test "inspect returns metadata and never exposes a resolved playlist URL", %{conn: conn} do
    FakeYtDlp.with_variant(:live, "http://127.0.0.1:4567/playlist.m3u8", fn ->
      conn = post(conn, ~p"/api/youtube/inspect", %{"url" => @url})
      body = json_response(conn, 200)

      assert body["data"]["title"] == "Hydra HLS fixture"
      assert body["data"]["is_live"] == true
      refute Jason.encode!(body) =~ "playlist.m3u8"
    end)
  end

  test "GET formats uses the authenticated inspect endpoint", %{conn: conn} do
    FakeYtDlp.with_variant(:vod, "http://127.0.0.1:4567/playlist.m3u8", fn ->
      conn = get(conn, ~p"/api/youtube/formats?url=#{@url}")
      assert json_response(conn, 200)["data"]["is_live"] == false
    end)
  end

  test "maps resolver errors to actionable HTTP errors", %{conn: conn} do
    errors = [
      {:invalid_url, 422, "INVALID_URL"},
      {:unsupported_format, 422, "UNSUPPORTED_FORMAT"},
      {:cookies_unreadable, 422, "COOKIES_UNREADABLE"},
      {:bot_check_challenge, 424, "BOT_CHECK_CHALLENGE"},
      {:bot_reload_challenge, 424, "BOT_CHECK_CHALLENGE"},
      {:private_video, 422, "PRIVATE_VIDEO"},
      {:not_live, 422, "NOT_LIVE"},
      {:geo_blocked, 422, "GEO_BLOCKED"},
      {:video_unavailable, 422, "VIDEO_UNAVAILABLE"},
      {:resolver_not_found, 404, "RESOLVER_NOT_FOUND"},
      {:resolver_timeout, 504, "RESOLVER_TIMEOUT"},
      {:invalid_output, 502, "INVALID_OUTPUT"},
      {:resolver_failed, 502, "RESOLVER_FAILED"},
      {:resolver_outdated, 502, "RESOLVER_OUTDATED"},
      {:media_access_forbidden, 502, "MEDIA_ACCESS_FORBIDDEN"},
      {:resolve_rate_limited, 429, "RESOLVER_RATE_LIMITED"}
    ]

    for {reason, status, code} <- errors do
      response = HydraSrtWeb.YoutubeController.render_error(conn, reason)
      body = json_response(response, status)
      assert body["error"]["code"] == code
      assert is_binary(body["error"]["message"])
    end
  end

  test "rejects hostile and non-YouTube input before resolver invocation", %{conn: conn} do
    hostile_urls = [
      "https://example.com/watch?v=fO9e9jnhYK8",
      "https://user:password@www.youtube.com/watch?v=fO9e9jnhYK8",
      "https://youtube.com.evil.tld/watch?v=fO9e9jnhYK8",
      "https://www.yоutube.com/watch?v=fO9e9jnhYK8",
      "https://www.youtube.com.evil.tld/watch?v=fO9e9jnhYK8",
      "https://www.youtube.com/watch?v=https://example.com"
    ]

    for url <- hostile_urls do
      response = post(conn, ~p"/api/youtube/inspect", %{"url" => url})
      assert json_response(response, 422)["error"]["code"] == "INVALID_URL"
    end
  end

  test "requires authentication", %{conn: conn} do
    conn =
      conn
      |> delete_req_header("authorization")
      |> post(~p"/api/youtube/inspect", %{"url" => @url})

    assert json_response(conn, 403)["error"] in ["Unauthorized", "Authorization header missing"]
  end

  test "rate limits repeated checks per authenticated user", %{conn: conn} do
    for _attempt <- 1..12 do
      assert :ok = HydraSrtWeb.YoutubeController.allow_inspect?(conn)
    end

    assert {:error, :rate_limited} = HydraSrtWeb.YoutubeController.allow_inspect?(conn)
  end

  test "refresh invalidates the canonical URL and returns accepted", %{conn: conn} do
    :ok = Phoenix.PubSub.subscribe(HydraSrt.PubSub, "youtube:refresh")

    response =
      post(conn, ~p"/api/youtube/refresh", %{
        "url" => "youtu.be/fO9e9jnhYK8?si=ignored",
        "format_id" => "96",
        "quality_policy" => "best[height<=1080]"
      })

    assert json_response(response, 202) == %{"data" => %{"accepted" => true}}
    assert_receive {:youtube_refresh, "https://www.youtube.com/watch?v=fO9e9jnhYK8"}, 250
  end
end

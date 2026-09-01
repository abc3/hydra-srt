defmodule HydraSrt.Youtube.ResolverYtDlpTest do
  use ExUnit.Case, async: false

  alias HydraSrt.TestSupport.FakeYtDlp
  alias HydraSrt.Youtube.ResolverYtDlp

  @watch_url "https://www.youtube.com/watch?v=fO9e9jnhYK8"
  @media_url "https://media.example/playlist.m3u8"

  test "requests declared bitrates in the JSON print template" do
    assert ResolverYtDlp.print_template() ==
             "%(.{id,is_live,format_id,duration,title,uploader,webpage_url,vbr,abr,tbr})j"
  end

  test "defaults to the client that works from deployment networks" do
    assert ResolverYtDlp.clients(player_clients: []) == ["android", "mweb"]
  end

  test "resolves live, vod, and expiring fixture metadata" do
    FakeYtDlp.with_variant(:live, @media_url, fn ->
      assert {:ok, @media_url, %{live: true, format_id: "96"} = metadata} =
               ResolverYtDlp.resolve(@watch_url, timeout_ms: 2_000)

      assert metadata.media_info["title"] == "Hydra HLS fixture"
      assert metadata.media_info["video"]["declared_bitrate_kbps"] == 948
      assert metadata.media_info["audio"]["declared_bitrate_kbps"] == 130
      assert metadata.media_info["declared_bitrate_kbps"] == 1078
    end)

    FakeYtDlp.with_variant(:vod, @media_url, fn ->
      assert {:ok, @media_url, %{live: false}} =
               ResolverYtDlp.resolve(@watch_url, timeout_ms: 2_000)
    end)

    FakeYtDlp.with_variant(:expiring, @media_url, fn ->
      assert {:ok, resolved_url, _metadata} = ResolverYtDlp.resolve(@watch_url, timeout_ms: 2_000)
      assert URI.parse(resolved_url).query =~ "expire="
    end)
  end

  test "classifies captured and fixture failures into actionable reasons" do
    fixture_reasons = [
      {:bot_check, :bot_check_challenge},
      {:challenge, :bot_reload_challenge},
      {:private, :private_video},
      {:not_live, :not_live},
      {:geo_blocked, :geo_blocked},
      {:unavailable, :video_unavailable}
    ]

    for {variant, reason} <- fixture_reasons do
      assert {:error, ^reason} =
               ResolverYtDlp.resolve(@watch_url, executable: FakeYtDlp.path(variant))
    end

    assert ResolverYtDlp.classify_error(
             File.read!("test/support/fixtures/captured_media_403.stderr")
           ) == :media_access_forbidden

    assert ResolverYtDlp.classify_error("ERROR: requested format is not available") ==
             :unsupported_format

    assert ResolverYtDlp.classify_error("ERROR: No video formats found!") ==
             :unsupported_format

    assert ResolverYtDlp.classify_error("ERROR: please update yt-dlp") == :resolver_outdated
    assert ResolverYtDlp.classify_error("an unexpected resolver failure") == :resolver_failed
  end

  test "returns unsupported format when no player clients remain" do
    assert {:error, :unsupported_format} = ResolverYtDlp.try_clients("unused", @watch_url, [], [])
  end

  test "returns resolver errors for missing binaries, failed launches, invalid output, and timeouts" do
    assert {:error, :resolver_not_found} =
             ResolverYtDlp.resolve(@watch_url, executable: "/missing/yt-dlp")

    assert {:error, :resolver_failed} =
             ResolverYtDlp.resolve(@watch_url,
               executable: FakeYtDlp.path(:live),
               port_launcher: fn _executable, _args -> :not_a_port end
             )

    launcher = fn _executable, _args -> output_port(["not metadata"], 0) end

    assert {:error, :invalid_output} =
             ResolverYtDlp.resolve(@watch_url,
               executable: FakeYtDlp.path(:live),
               port_launcher: launcher
             )

    outdated_launcher = fn _executable, _args ->
      output_port(
        [
          @media_url,
          ~s({"id":"video-1","is_live":false,"format_id":"96"}),
          "yt-dlp version 2023.12.1"
        ],
        0
      )
    end

    assert {:error, :resolver_outdated} =
             ResolverYtDlp.resolve(@watch_url,
               executable: FakeYtDlp.path(:live),
               port_launcher: outdated_launcher
             )

    assert {:error, :resolver_timeout} =
             ResolverYtDlp.resolve(@watch_url,
               executable: FakeYtDlp.path(:hang),
               timeout_ms: 50
             )
  end

  test "decodes JSON metadata and rejects malformed JSON metadata" do
    output =
      "#{@media_url}\n" <>
        ~s({"id":"video-1","is_live":true,"format_id":"137","duration":42,"title":"Title","uploader":"Uploader","webpage_url":"https://www.youtube.com/watch?v=video-1"})

    assert {:ok, @media_url, metadata} = ResolverYtDlp.parse_output(output)
    assert metadata.id == "video-1"
    assert metadata.live
    assert metadata.format_id == "137"
    assert metadata.duration == "42"
    assert metadata.title == "Title"
    assert metadata.uploader == "Uploader"
    assert metadata.webpage_url == "https://www.youtube.com/watch?v=video-1"

    assert {:error, :invalid_output} = ResolverYtDlp.parse_metadata_line("{malformed json}")
  end

  test "keeps declared video, audio, and total bitrates on their respective lanes" do
    line =
      ~s({"id":"video-1","is_live":true,"format_id":"96","vbr":948,"abr":130,"tbr":1078})

    assert {:ok, metadata} = ResolverYtDlp.parse_metadata_line(line)
    assert metadata.media_info["video"]["declared_bitrate_kbps"] == 948
    assert metadata.media_info["audio"]["declared_bitrate_kbps"] == 130
    assert metadata.media_info["declared_bitrate_kbps"] == 1078
  end

  test "omits declared bitrate keys independently when values are missing" do
    assert {:ok, metadata} =
             ResolverYtDlp.parse_metadata_line(
               ~s({"id":"video-1","is_live":true,"format_id":"96","abr":130,"tbr":130})
             )

    refute Map.has_key?(metadata.media_info["video"], "declared_bitrate_kbps")
    assert metadata.media_info["audio"]["declared_bitrate_kbps"] == 130
    assert metadata.media_info["declared_bitrate_kbps"] == 130

    assert {:ok, metadata} =
             ResolverYtDlp.parse_metadata_line(
               ~s({"id":"video-1","is_live":true,"format_id":"96","vbr":948,"tbr":948})
             )

    assert metadata.media_info["video"]["declared_bitrate_kbps"] == 948
    refute Map.has_key?(metadata.media_info["audio"], "declared_bitrate_kbps")
    assert metadata.media_info["declared_bitrate_kbps"] == 948
  end

  test "omits all declared bitrate keys when values are absent or null" do
    for line <- [
          ~s({"id":"video-1","is_live":true,"format_id":"96"}),
          ~s({"id":"video-1","is_live":true,"format_id":"96","vbr":null,"abr":null,"tbr":null})
        ] do
      assert {:ok, metadata} = ResolverYtDlp.parse_metadata_line(line)
      refute Map.has_key?(metadata.media_info["video"], "declared_bitrate_kbps")
      refute Map.has_key?(metadata.media_info["audio"], "declared_bitrate_kbps")
      refute Map.has_key?(metadata.media_info, "declared_bitrate_kbps")
    end
  end

  test "rounds declared bitrate floats to integer kbps" do
    line =
      ~s({"id":"video-1","is_live":true,"format_id":"96","vbr":948.6,"abr":130.4,"tbr":1079.0})

    assert {:ok, metadata} = ResolverYtDlp.parse_metadata_line(line)
    assert metadata.media_info["video"]["declared_bitrate_kbps"] == 949
    assert metadata.media_info["audio"]["declared_bitrate_kbps"] == 130
    assert metadata.media_info["declared_bitrate_kbps"] == 1079
  end

  test "falls back to the legacy pipe-delimited metadata shape" do
    line = "#{@media_url}|true|is_live|96|h264|mp4a.40.2|1920|1080|29.97|4500|Legacy title"

    assert {:ok, @media_url, metadata} = ResolverYtDlp.parse_output(@media_url <> "\n" <> line)
    assert metadata.live
    assert metadata.format_id == "96"
    assert metadata.title == "Legacy title"

    assert metadata.media_info["video"] == %{
             "codec" => "h264",
             "width" => 1920,
             "height" => 1080,
             "fps" => 29.97
           }

    assert metadata.media_info["audio"] == %{"codec" => "mp4a.40.2"}
  end

  test "parses live booleans and string statuses" do
    assert ResolverYtDlp.parse_live(true)
    refute ResolverYtDlp.parse_live(false)
    assert ResolverYtDlp.parse_live("true")
    refute ResolverYtDlp.parse_live("false")
    assert ResolverYtDlp.parse_live("false", "is_live")
    refute ResolverYtDlp.parse_live("false", "not_live")
  end

  test "tries the next player client after an unsupported first result" do
    shell = System.find_executable("sh")
    assert is_binary(shell)

    launcher = fn _executable, args ->
      client = Enum.find(args, &String.starts_with?(&1, "youtube:player_client="))

      lines =
        if client == "youtube:player_client=mweb" do
          [
            @media_url,
            "#{@media_url}|false|not_live|96|h264|none|1920|1080|30|1000|video"
          ]
        else
          [
            @media_url,
            ~s({"id":"video-1","is_live":false,"format_id":"96","title":"video"})
          ]
        end

      output_port(lines, 0, shell)
    end

    assert {:ok, output, "android"} =
             ResolverYtDlp.try_clients(
               "unused",
               @watch_url,
               [port_launcher: launcher],
               ["mweb", "android"]
             )

    assert output =~ @media_url
  end

  test "tries the next client after a bot check and keeps its metadata" do
    fixture = "test/support/fixtures/fake_yt_dlp_bot_then_android"
    old_url = System.get_env("YOUTUBE_TEST_URL")
    System.put_env("YOUTUBE_TEST_URL", @media_url)

    try do
      assert {:ok, @media_url, metadata} =
               ResolverYtDlp.resolve(@watch_url,
                 executable: fixture,
                 player_clients: ["mweb", "android"],
                 timeout_ms: 2_000
               )

      assert metadata.title == "android fixture"
      assert metadata.uploader == "android"
    after
      restore_env("YOUTUBE_TEST_URL", old_url)
    end
  end

  test "stops on a video-level error without trying another client" do
    shell = System.find_executable("sh")
    assert is_binary(shell)

    launcher = fn _executable, args ->
      client = Enum.find(args, &String.starts_with?(&1, "youtube:player_client="))
      send(self(), {:invoked_client, client})
      output_port(["ERROR: [youtube] This video is private"], 1, shell)
    end

    assert {:error, :private_video} =
             ResolverYtDlp.try_clients(
               "unused",
               @watch_url,
               [port_launcher: launcher],
               ["android", "mweb"]
             )

    assert_receive {:invoked_client, "youtube:player_client=android"}
    refute_receive {:invoked_client, "youtube:player_client=mweb"}
  end

  test "returns the last error after every client fails" do
    shell = System.find_executable("sh")
    assert is_binary(shell)

    launcher = fn _executable, args ->
      client = Enum.find(args, &String.starts_with?(&1, "youtube:player_client="))

      output =
        case client do
          "youtube:player_client=android" -> "an unexpected resolver failure"
          "youtube:player_client=mweb" -> "ERROR: [youtube] Sign in to confirm you're not a bot"
        end

      send(self(), {:invoked_client, client})
      output_port([output], 1, shell)
    end

    assert {:error, :bot_check_challenge} =
             ResolverYtDlp.try_clients(
               "unused",
               @watch_url,
               [port_launcher: launcher],
               ["android", "mweb"]
             )

    assert_receive {:invoked_client, "youtube:player_client=android"}
    assert_receive {:invoked_client, "youtube:player_client=mweb"}
  end

  test "returns a single client error without falling back" do
    shell = System.find_executable("sh")
    assert is_binary(shell)

    launcher = fn _executable, _args ->
      output_port(["ERROR: [youtube] Sign in to confirm you're not a bot"], 1, shell)
    end

    assert {:error, :bot_check_challenge} =
             ResolverYtDlp.try_clients(
               "unused",
               @watch_url,
               [port_launcher: launcher],
               ["android"]
             )
  end

  test "adds cookies only when a cookies path is configured" do
    without_cookies = ResolverYtDlp.yt_dlp_args(@watch_url, "best", "mweb", cookies_path: nil)

    with_cookies =
      ResolverYtDlp.yt_dlp_args(@watch_url, "best", "mweb", cookies_path: "/tmp/cookies.txt")

    refute "--cookies" in without_cookies

    assert with_cookies
           |> Enum.chunk_every(2, 1, :discard)
           |> Enum.member?(["--cookies", "/tmp/cookies.txt"])
  end

  @spec output_port([String.t()], integer(), String.t() | nil) :: port()
  def output_port(lines, status, shell \\ System.find_executable("sh"))

  def output_port(lines, status, shell) when is_list(lines) and is_integer(status) do
    script =
      lines
      |> Enum.map_join(" ", fn line -> "'" <> String.replace(line, "'", "'\\''") <> "'" end)
      |> then(&("printf '%s\\n' " <> &1 <> "; exit " <> Integer.to_string(status)))

    Port.open({:spawn_executable, String.to_charlist(shell)}, [
      :binary,
      :exit_status,
      :use_stdio,
      {:args, ["-c", script]}
    ])
  end

  @spec restore_env(String.t(), String.t() | nil) :: :ok
  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)
end

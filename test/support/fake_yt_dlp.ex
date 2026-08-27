defmodule HydraSrt.TestSupport.FakeYtDlp do
  @moduledoc "Helpers for selecting the checked-in fake yt-dlp executables."

  @fixture_dir Path.expand("fixtures", __DIR__)

  @variants [
    live: "fake_yt_dlp_live",
    vod: "fake_yt_dlp_vod",
    expiring: "fake_yt_dlp_expiring",
    bot_check: "fake_yt_dlp_bot_check",
    private: "fake_yt_dlp_private",
    unavailable: "fake_yt_dlp_unavailable",
    not_live: "fake_yt_dlp_not_live",
    geo_blocked: "fake_yt_dlp_geo_blocked",
    challenge: "fake_yt_dlp_challenge",
    hang: "fake_yt_dlp_hang"
  ]

  @spec path(atom()) :: String.t()
  def path(variant) when is_atom(variant) do
    filename = Keyword.fetch!(@variants, variant)
    Path.join(@fixture_dir, filename)
  end

  @spec variants() :: [atom()]
  def variants, do: Keyword.keys(@variants)

  @spec configure!(atom(), String.t(), keyword()) :: String.t()
  def configure!(variant, url, opts \\ []) when is_atom(variant) and is_binary(url) do
    fixture = path(variant)
    true = File.exists?(fixture)
    System.put_env("YT_DLP_PATH", fixture)
    System.put_env("YOUTUBE_TEST_URL", url)

    if variant == :expiring do
      System.put_env("YOUTUBE_TEST_EXPIRE", Integer.to_string(System.system_time(:second) + 10))
    else
      System.delete_env("YOUTUBE_TEST_EXPIRE")
    end

    if format_id = Keyword.get(opts, :format_id) do
      System.put_env("YOUTUBE_TEST_FORMAT_ID", to_string(format_id))
    else
      System.delete_env("YOUTUBE_TEST_FORMAT_ID")
    end

    fixture
  end

  @spec with_variant(atom(), String.t(), (-> term())) :: term()
  def with_variant(variant, url, fun) when is_function(fun, 0),
    do: with_variant(variant, url, [], fun)

  @spec with_variant(atom(), String.t(), keyword(), (-> term())) :: term()
  def with_variant(variant, url, opts, fun) when is_function(fun, 0) do
    old_path = System.get_env("YT_DLP_PATH")
    old_url = System.get_env("YOUTUBE_TEST_URL")
    old_expire = System.get_env("YOUTUBE_TEST_EXPIRE")
    old_format_id = System.get_env("YOUTUBE_TEST_FORMAT_ID")

    configure!(variant, url, opts)

    try do
      fun.()
    after
      restore_env("YT_DLP_PATH", old_path)
      restore_env("YOUTUBE_TEST_URL", old_url)
      restore_env("YOUTUBE_TEST_EXPIRE", old_expire)
      restore_env("YOUTUBE_TEST_FORMAT_ID", old_format_id)
    end
  end

  @spec restore_env(String.t(), String.t() | nil) :: :ok
  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)
end

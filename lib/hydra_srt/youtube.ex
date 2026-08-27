defmodule HydraSrt.Youtube do
  @moduledoc "YouTube URL resolution facade used by the route control plane."

  # inspect/2 is the contract name for listing renditions, so the Kernel import
  # has to step aside for it.
  import Kernel, except: [inspect: 2]

  alias HydraSrt.Youtube.Cache
  alias HydraSrt.Youtube.Resolver
  alias HydraSrt.Youtube.Url

  @type error_reason ::
          :invalid_url
          | :bot_check_challenge
          | :resolver_not_found
          | :resolver_timeout
          | :resolver_failed
          | :invalid_output
          | :unsupported_format
          | :cookies_unreadable
          | :private_video
          | :not_live
          | :geo_blocked
          | :video_unavailable
          | :bot_reload_challenge
          | :resolver_outdated
          | :media_access_forbidden
          | :resolve_rate_limited
          | :not_implemented

  @type resolved_media :: %{
          required(:uri) => String.t(),
          required(:live) => boolean(),
          required(:format_id) => String.t() | nil,
          required(:media_info) => map()
        }

  @type variant :: %{
          required(:format_id) => String.t(),
          required(:label) => String.t(),
          optional(:height) => non_neg_integer() | nil,
          optional(:width) => non_neg_integer() | nil,
          optional(:fps) => number() | nil,
          optional(:has_video) => boolean(),
          optional(:has_audio) => boolean()
        }

  @type inspect_result ::
          {:ok, %{variants: [variant()], live: boolean()}} | {:error, error_reason()}
  @type resolve_result :: {:ok, resolved_media()} | {:error, error_reason()}

  @spec resolve(String.t(), keyword()) :: resolve_result()
  def resolve(url, opts \\ []) when is_binary(url) and is_list(opts) do
    with {:ok, canonical_url} <- Url.canonicalize(url),
         :ok <- cookies_readable(opts),
         {:ok, video_id} <- Url.video_id(canonical_url) do
      resolve_cached(canonical_url, video_id, opts)
    end
  end

  @spec inspect(String.t(), keyword()) :: inspect_result()
  def inspect(url, opts \\ []) when is_binary(url) and is_list(opts) do
    case resolve(url, opts) do
      {:ok, media} ->
        media_info = media.media_info || %{}

        {:ok,
         %{
           variants: [variant_from_media(media)],
           live: media.live,
           title: media_info["title"],
           media_info: media_info
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec formats(String.t(), keyword()) :: inspect_result()
  def formats(url, opts \\ []), do: inspect(url, opts)

  @spec invalidate(String.t()) :: :ok
  def invalidate(url) when is_binary(url) do
    case Url.video_id(url) do
      {:ok, video_id} ->
        :ok = Cache.invalidate(video_id)
        cancel_refresh(url)
        :ok

      _ ->
        :ok
    end
  end

  @spec error_message(error_reason()) :: String.t()
  def error_message(:invalid_url),
    do: "Enter a YouTube watch URL, such as https://www.youtube.com/watch?v=..."

  def error_message(:bot_check_challenge),
    do:
      "YouTube asked for a bot check. Configure a Netscape cookies file from a real account and try again."

  def error_message(:bot_reload_challenge),
    do:
      "YouTube returned an anti-bot challenge. Configure a Netscape cookies file and refresh the source."

  def error_message(:private_video),
    do:
      "The YouTube video is private, members-only, or age-gated. Sign in with an account that can view it."

  def error_message(:not_live),
    do:
      "The YouTube live event has not started or has ended. Check the video status and try again later."

  def error_message(:geo_blocked),
    do: "The YouTube video is blocked in this server's region. Use an allowed region or source."

  def error_message(:video_unavailable),
    do: "The YouTube video does not exist or is unavailable. Check the URL and its visibility."

  def error_message(:resolver_not_found),
    do: "yt-dlp is not installed or YT_DLP_PATH is invalid. Install a current yt-dlp binary."

  def error_message(:resolver_timeout),
    do: "yt-dlp took too long to resolve the video. Check network access and try again."

  def error_message(:resolver_outdated),
    do: "yt-dlp is too old for this YouTube extractor. Upgrade yt-dlp and try again."

  def error_message(:unsupported_format),
    do:
      "YouTube did not provide a muxed audio/video HLS format for the selected quality. Choose another quality or update yt-dlp."

  def error_message(:cookies_unreadable),
    do:
      "The YouTube cookies file cannot be read. Check its path and permissions; it grants access to the account used to resolve this source."

  def error_message(:invalid_output),
    do:
      "yt-dlp returned output HydraSRT could not understand. Upgrade yt-dlp and check the resolver logs."

  def error_message(:media_access_forbidden),
    do:
      "yt-dlp resolved the playlist, but YouTube refused its media segments with HTTP 403. Check cookies, PO tokens, and yt-dlp freshness."

  def error_message(:resolve_rate_limited),
    do:
      "YouTube resolution is temporarily rate-limited to protect the server. Wait before refreshing."

  def error_message(:resolver_failed),
    do:
      "yt-dlp failed to resolve the video. Check the URL, network access, and resolver diagnostics."

  def error_message(:not_implemented), do: "YouTube resolution is not available."

  @spec client_error(error_reason()) :: String.t()
  def client_error(reason), do: error_message(reason)

  @spec resolve_cached(String.t(), String.t(), keyword()) :: resolve_result()
  def resolve_cached(canonical_url, video_id, opts) do
    case Cache.get(video_id, opts) do
      {:hit, result} ->
        result

      {:blocked, result} ->
        result

      :miss ->
        result = resolve_uncached(canonical_url, opts)
        resolved_url = resolved_url(result)
        :ok = Cache.put(video_id, opts, result, resolved_url)
        result
    end
  end

  @spec resolve_uncached(String.t(), keyword()) :: resolve_result()
  def resolve_uncached(canonical_url, opts) do
    case Resolver.resolve(canonical_url, opts) do
      {:ok, resolved_url, metadata} ->
        media = media_from_metadata(resolved_url, metadata)

        case Keyword.get(opts, :format_id) do
          nil -> {:ok, media}
          requested -> {:ok, maybe_mark_fallback(media, requested)}
        end

      {:error, :unsupported_format} ->
        # The exact itag the operator picked can disappear when a broadcaster
        # restarts at a different quality. Retry on the policy alone and mark
        # the result so the caller can tell the operator the quality changed.
        case Keyword.get(opts, :format_id) do
          requested when is_binary(requested) and requested != "" ->
            fallback_opts = Keyword.delete(opts, :format_id)

            case Resolver.resolve(canonical_url, fallback_opts) do
              {:ok, resolved_url, metadata} ->
                media = media_from_metadata(resolved_url, metadata)
                {:ok, put_media_info(media, "format_fallback", true)}

              {:error, reason} ->
                {:error, reason}
            end

          _ ->
            {:error, :unsupported_format}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec media_from_metadata(String.t(), Resolver.metadata()) :: resolved_media()
  def media_from_metadata(uri, metadata) do
    media_info =
      metadata.media_info
      |> maybe_put_media_info("resolver_version", metadata.resolver_version)

    %{uri: uri, live: metadata.live, format_id: metadata.format_id, media_info: media_info}
  end

  @spec maybe_put_media_info(map(), String.t(), term()) :: map()
  def maybe_put_media_info(map, _key, nil), do: map
  def maybe_put_media_info(map, key, value), do: Map.put(map, key, value)

  @spec maybe_mark_fallback(resolved_media(), term()) :: resolved_media()
  def maybe_mark_fallback(media, requested) do
    if media.format_id != to_string(requested),
      do: put_media_info(media, "format_fallback", true),
      else: media
  end

  @spec put_media_info(resolved_media(), String.t(), term()) :: resolved_media()
  def put_media_info(media, key, value) do
    %{media | media_info: Map.put(media.media_info, key, value)}
  end

  @spec resolved_url(resolve_result()) :: String.t() | nil
  def resolved_url({:ok, media}), do: media.uri
  def resolved_url(_result), do: nil

  @spec variant_from_media(resolved_media()) :: variant()
  def variant_from_media(media) do
    video = media.media_info["video"] || %{}
    audio = media.media_info["audio"] || %{}
    codec_video = video["codec"]
    codec_audio = audio["codec"]

    %{
      format_id: media.format_id || "unknown",
      label: variant_label(media.format_id, video, codec_video, codec_audio),
      width: video["width"],
      height: video["height"],
      fps: video["fps"],
      has_video: is_binary(codec_video) or (is_nil(codec_video) and is_binary(media.format_id)),
      has_audio: is_binary(codec_audio) or (is_nil(codec_audio) and is_binary(media.format_id))
    }
  end

  @spec variant_label(String.t() | nil, map(), String.t() | nil, String.t() | nil) :: String.t()
  def variant_label(format_id, video, video_codec, audio_codec) do
    quality =
      if is_integer(video["height"]),
        do: "#{video["height"]}p",
        else: "format #{format_id || "unknown"}"

    codecs = [video_codec, audio_codec] |> Enum.filter(&is_binary/1) |> Enum.join(" · ")
    if codecs == "", do: quality, else: "#{quality} · #{codecs}"
  end

  @spec cookies_readable(keyword()) :: :ok | {:error, :cookies_unreadable}
  def cookies_readable(opts) do
    youtube_config = Application.get_env(:hydra_srt, :youtube, [])

    path =
      Keyword.get(
        opts,
        :cookies_path,
        youtube_config[:cookies_path] || System.get_env("YOUTUBE_COOKIES_PATH")
      )

    case path do
      nil ->
        :ok

      "" ->
        :ok

      value when is_binary(value) ->
        # File has no readable? check, so ask the filesystem for the access mode.
        case File.stat(value) do
          {:ok, %File.Stat{type: :regular, access: access}} when access in [:read, :read_write] ->
            :ok

          _ ->
            {:error, :cookies_unreadable}
        end

      _ ->
        {:error, :cookies_unreadable}
    end
  end

  @spec cancel_refresh(String.t()) :: :ok
  def cancel_refresh(url) do
    if Process.whereis(HydraSrt.Youtube.RefreshScheduler),
      do: HydraSrt.Youtube.RefreshScheduler.cancel(url)

    :ok
  end
end

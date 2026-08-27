defmodule HydraSrtWeb.YoutubeController do
  @moduledoc """
  Handles authenticated YouTube metadata inspection and cache refresh requests.

  The controller only returns metadata. Resolved playlist URLs remain inside the
  control plane because they are bearer credentials.
  """

  use HydraSrtWeb, :controller

  # The inspect action shadows Kernel.inspect/2, which the router needs by name.
  import Kernel, except: [inspect: 2]

  alias HydraSrt.Youtube
  alias HydraSrt.Youtube.Url

  @rate_limit 12
  @rate_window_ms :timer.minutes(1)
  @refresh_topic "youtube:refresh"

  @spec inspect(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def inspect(conn, params) do
    with {:ok, canonical_url} <- canonical_url(params["url"]),
         :ok <- allow_inspect?(conn) do
      {canonical_url, inspect_options(canonical_url, params)}
      |> inspect_youtube()
      |> render_inspect(conn)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  @spec formats(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def formats(conn, params), do: inspect(conn, params)

  @spec refresh(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def refresh(conn, params) do
    with {:ok, canonical_url} <- canonical_url(params["url"]),
         :ok <- allow_refresh?(conn) do
      options = refresh_options(params) |> Keyword.put(:delay_ms, 1)
      :ok = Youtube.invalidate(canonical_url)
      :ok = schedule_refresh(canonical_url, options)

      conn
      |> put_status(202)
      |> json(%{data: %{accepted: true}})
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  @spec canonical_url(term()) :: {:ok, String.t()} | {:error, :invalid_url}
  def canonical_url(url) when is_binary(url) do
    case Url.canonicalize(url) do
      {:ok, canonical} when is_binary(canonical) -> {:ok, canonical}
      _ -> {:error, :invalid_url}
    end
  end

  def canonical_url(_url), do: {:error, :invalid_url}

  @spec inspect_options(String.t(), map()) :: keyword()
  def inspect_options(_canonical_url, params) when is_map(params) do
    case params["quality_policy"] do
      policy when is_binary(policy) and policy != "" -> [quality_policy: policy]
      _ -> []
    end
  end

  @spec refresh_options(map()) :: keyword()
  def refresh_options(params) when is_map(params) do
    []
    |> maybe_option(:format_id, params["format_id"])
    |> maybe_option(:quality_policy, params["quality_policy"])
  end

  @spec maybe_option(keyword(), atom(), term()) :: keyword()
  def maybe_option(options, _key, nil), do: options
  def maybe_option(options, _key, ""), do: options

  def maybe_option(options, key, value) when is_binary(value),
    do: Keyword.put(options, key, value)

  def maybe_option(options, _key, _value), do: options

  @spec inspect_youtube({String.t(), keyword()}) :: Youtube.inspect_result()
  def inspect_youtube({canonical_url, options}) do
    Youtube.inspect(canonical_url, options)
  end

  @spec render_inspect(Youtube.inspect_result(), Plug.Conn.t()) :: Plug.Conn.t()
  def render_inspect({:ok, result}, conn) when is_map(result) do
    media_info = result_value(result, :media_info) || %{}

    data = %{
      title: result_value(result, :title) || result_value(media_info, :title),
      is_live: result_value(result, :is_live) || result_value(result, :live) == true,
      live_status: result_value(result, :live_status) || result_value(media_info, :live_status),
      variants: Enum.map(result_value(result, :variants) || [], &serialize_variant/1)
    }

    json(conn, %{data: data})
  end

  def render_inspect({:error, reason}, conn), do: render_error(conn, reason)

  @spec serialize_variant(map()) :: map()
  def serialize_variant(variant) when is_map(variant) do
    media_info = result_value(variant, :media_info) || %{}
    video_info = result_value(media_info, :video) || %{}
    audio_info = result_value(media_info, :audio) || %{}
    vcodec = result_value(variant, :vcodec) || result_value(video_info, :codec)
    acodec = result_value(variant, :acodec) || result_value(audio_info, :codec)
    fps = result_value(variant, :fps) || result_value(video_info, :fps)
    tbr = result_value(variant, :tbr) || result_value(media_info, :tbr)

    %{
      format_id: result_value(variant, :format_id),
      width: result_value(variant, :width) || result_value(video_info, :width),
      height: result_value(variant, :height) || result_value(video_info, :height),
      fps: fps,
      vcodec: vcodec,
      acodec: acodec,
      tbr: tbr,
      label: result_value(variant, :label) || display_label(variant, vcodec, acodec, fps, tbr)
    }
  end

  @spec display_label(map(), term(), term(), term(), term()) :: String.t()
  def display_label(variant, vcodec, acodec, fps, tbr) when is_map(variant) do
    resolution =
      case result_value(variant, :height) do
        height when is_integer(height) and height > 0 -> "#{height}p"
        _ -> "unknown"
      end

    frame_rate = if is_number(fps), do: format_number(fps), else: nil
    video = codec_label(vcodec)
    audio = codec_label(acodec)
    bitrate = if is_number(tbr), do: "~#{format_number(tbr / 1000)} Mbps", else: nil

    [resolution <> (frame_rate || ""), video, audio, bitrate]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  @spec result_value(map(), atom()) :: term()
  def result_value(result, key) when is_map(result) and is_atom(key) do
    case result[key] do
      nil -> result[Atom.to_string(key)]
      value -> value
    end
  end

  @spec format_number(number()) :: String.t()
  def format_number(number) when is_integer(number), do: Integer.to_string(number)

  def format_number(number) when is_float(number) do
    number
    |> :erlang.float_to_binary(decimals: 1)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  @spec codec_label(term()) :: String.t() | nil
  def codec_label(codec) when is_binary(codec) do
    cond do
      String.starts_with?(codec, "avc") or String.contains?(codec, "h264") -> "H.264"
      String.starts_with?(codec, "mp4a") or String.contains?(codec, "aac") -> "AAC"
      String.starts_with?(codec, "av01") -> "AV1"
      String.starts_with?(codec, "vp09") or String.starts_with?(codec, "vp9") -> "VP9"
      codec == "none" -> nil
      true -> codec
    end
  end

  def codec_label(_codec), do: nil

  @spec render_error(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def render_error(conn, reason) do
    {status, code, message} = error_details(reason)

    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  @spec error_details(term()) :: {pos_integer(), String.t(), String.t()}
  def error_details(:invalid_url), do: {422, "INVALID_URL", "Enter a valid YouTube watch URL."}

  def error_details(:unsupported_format),
    do: {422, "UNSUPPORTED_FORMAT", "YouTube did not provide a compatible muxed HLS format."}

  def error_details(:cookies_unreadable),
    do: {422, "COOKIES_UNREADABLE", "The configured YouTube cookies file cannot be read."}

  def error_details(:bot_check_challenge),
    do:
      {424, "BOT_CHECK_CHALLENGE",
       "YouTube requested bot verification. Configure a readable cookies file and try again."}

  def error_details(:bot_reload_challenge),
    do:
      {424, "BOT_CHECK_CHALLENGE",
       "YouTube returned an anti-bot challenge. Configure a readable cookies file and try again."}

  def error_details(:private_video),
    do: {422, "PRIVATE_VIDEO", "The YouTube video is private or requires account access."}

  def error_details(:not_live),
    do: {422, "NOT_LIVE", "The YouTube live event has not started or has already ended."}

  def error_details(:geo_blocked),
    do: {422, "GEO_BLOCKED", "The YouTube video is unavailable in this server's region."}

  def error_details(:video_unavailable),
    do: {422, "VIDEO_UNAVAILABLE", "The YouTube video does not exist or is unavailable."}

  def error_details(:resolver_not_found),
    do: {404, "RESOLVER_NOT_FOUND", "The YouTube resolver is not installed on this node."}

  def error_details(:resolver_timeout),
    do: {504, "RESOLVER_TIMEOUT", "YouTube metadata lookup timed out."}

  def error_details(:invalid_output),
    do: {502, "INVALID_OUTPUT", "The YouTube resolver returned invalid metadata."}

  def error_details(:resolver_failed),
    do: {502, "RESOLVER_FAILED", "YouTube metadata lookup failed."}

  def error_details(:resolver_outdated),
    do:
      {502, "RESOLVER_OUTDATED", "The YouTube resolver is out of date. Update it and try again."}

  def error_details(:media_access_forbidden),
    do:
      {502, "MEDIA_ACCESS_FORBIDDEN",
       "YouTube refused the resolved media. Check cookies and that the resolver is up to date."}

  def error_details(:resolve_rate_limited),
    do:
      {429, "RESOLVER_RATE_LIMITED",
       "YouTube resolution is temporarily rate-limited. Try again later."}

  def error_details(:not_implemented),
    do: {501, "NOT_IMPLEMENTED", "YouTube inspection is not available."}

  def error_details(:rate_limited),
    do: {429, "RATE_LIMITED", "Too many YouTube checks. Try again in a minute."}

  def error_details(_reason), do: {502, "RESOLVER_FAILED", "YouTube metadata lookup failed."}

  @spec allow_inspect?(Plug.Conn.t()) :: :ok | {:error, :rate_limited}
  def allow_inspect?(conn), do: allow_request?(conn, "inspect")

  @spec allow_refresh?(Plug.Conn.t()) :: :ok | {:error, :rate_limited}
  def allow_refresh?(conn), do: allow_request?(conn, "refresh")

  @spec allow_request?(Plug.Conn.t(), String.t()) :: :ok | {:error, :rate_limited}
  def allow_request?(conn, operation) when is_binary(operation) do
    key = "youtube:rate:#{operation}:#{auth_principal(conn)}"

    case Cachex.incr(HydraSrt.Cache, key, 1, initial: 0) do
      {:ok, count} when count <= @rate_limit ->
        if count == 1, do: Cachex.expire(HydraSrt.Cache, key, @rate_window_ms)
        :ok

      {:ok, _count} ->
        {:error, :rate_limited}

      {:error, _reason} ->
        {:error, :rate_limited}
    end
  end

  @spec auth_principal(Plug.Conn.t()) :: String.t()
  def auth_principal(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> HydraSrt.Auth.hash_token(token)
      _ -> "anonymous"
    end
  end

  @spec schedule_refresh(String.t(), keyword()) :: :ok
  def schedule_refresh(canonical_url, options)
      when is_binary(canonical_url) and is_list(options) do
    # The route handler acts on the broadcast; the scheduler only re-times its own
    # timer and no-ops when the feature is off, so both always run.
    _ = HydraSrt.Youtube.RefreshScheduler.schedule(canonical_url, options)

    _ =
      Phoenix.PubSub.broadcast(HydraSrt.PubSub, @refresh_topic, {:youtube_refresh, canonical_url})

    :ok
  end
end

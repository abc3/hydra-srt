defmodule HydraSrt.Youtube.ResolverYtDlp do
  @moduledoc "Resolves a YouTube watch URL to an HLS playlist using the yt-dlp binary."

  @behaviour HydraSrt.Youtube.Resolver

  # yt-dlp does not expand escapes in --print, so a "\t" template emits the two
  # literal characters and nothing splits on a real tab. Ask for JSON instead.
  @print_template "%(.{id,is_live,format_id,duration,title,uploader,webpage_url,vbr,abr,tbr})j"
  @default_timeout_ms :timer.seconds(15)
  @default_clients ["android", "mweb"]

  @type metadata :: HydraSrt.Youtube.Resolver.metadata()

  @type result :: HydraSrt.Youtube.Resolver.result()
  @type port_launcher :: (String.t(), [String.t()] -> port())

  @impl HydraSrt.Youtube.Resolver
  @spec resolve(String.t(), keyword()) :: result()
  def resolve(url, opts \\ []) when is_binary(url) and is_list(opts) do
    with {:ok, executable} <- executable(opts),
         {:ok, output, _client} <- try_clients(executable, url, opts, clients(opts)),
         {:ok, resolved_url, metadata} <- parse_output(output),
         :ok <- ensure_muxed(metadata),
         :ok <- ensure_fresh(metadata) do
      {:ok, resolved_url, metadata}
    end
  end

  @spec inspect(String.t(), keyword()) :: {:ok, metadata()} | {:error, atom()}
  def inspect(url, opts \\ []) when is_binary(url) and is_list(opts) do
    case resolve(url, opts) do
      {:ok, _resolved_url, metadata} -> {:ok, metadata}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec executable(keyword()) :: {:ok, String.t()} | {:error, :resolver_not_found}
  def executable(opts) do
    configured = Keyword.get(opts, :executable, System.get_env("YT_DLP_PATH"))

    path =
      case configured do
        value when is_binary(value) and value != "" -> value
        _ -> System.find_executable("yt-dlp")
      end

    if is_binary(path) and File.exists?(path) do
      {:ok, path}
    else
      {:error, :resolver_not_found}
    end
  end

  @spec clients(keyword()) :: [String.t()]
  def clients(opts) do
    youtube_config = Application.get_env(:hydra_srt, :youtube, [])
    configured = Keyword.get(opts, :player_clients, youtube_config[:player_clients])

    case configured do
      clients when is_list(clients) ->
        clients
        |> Enum.map(&to_string/1)
        |> Enum.filter(&(&1 != ""))
        |> case do
          [] -> @default_clients
          clients -> clients
        end

      _ ->
        @default_clients
    end
  end

  @spec print_template() :: String.t()
  def print_template, do: @print_template

  @spec yt_dlp_args(String.t(), String.t(), String.t(), keyword()) :: [String.t()]
  def yt_dlp_args(url, selector, client, opts)
      when is_binary(url) and is_binary(selector) and is_binary(client) and is_list(opts) do
    youtube_config = Application.get_env(:hydra_srt, :youtube, [])

    cookies =
      Keyword.get(
        opts,
        :cookies_path,
        youtube_config[:cookies_path] || System.get_env("YOUTUBE_COOKIES_PATH")
      )

    [
      "--no-warnings",
      "--no-playlist",
      "-f",
      selector,
      "--extractor-args",
      "youtube:player_client=#{client}",
      "--print",
      @print_template,
      "--get-url"
    ]
    |> maybe_add_cookies(cookies)
    |> Kernel.++([url])
  end

  @spec maybe_add_cookies([String.t()], String.t() | nil) :: [String.t()]
  def maybe_add_cookies(args, cookies)
      when is_list(args) and is_binary(cookies) and cookies != "" do
    args ++ ["--cookies", cookies]
  end

  def maybe_add_cookies(args, _cookies), do: args

  @spec try_clients(String.t(), String.t(), keyword(), [String.t()]) ::
          {:ok, binary(), String.t()} | {:error, atom()}
  def try_clients(executable, url, opts, [client | rest]) do
    selector = selection(opts)

    case run(executable, yt_dlp_args(url, selector, client, opts), opts) do
      {:ok, output} ->
        case parse_output(output) do
          {:ok, _resolved_url, metadata} ->
            case ensure_muxed(metadata) do
              :ok -> {:ok, output, client}
              {:error, reason} -> retry_or_return(reason, executable, url, opts, rest)
            end

          {:error, reason} ->
            retry_or_return(reason, executable, url, opts, rest)
        end

      {:error, reason} ->
        retry_or_return(reason, executable, url, opts, rest)
    end
  end

  def try_clients(_executable, _url, _opts, []), do: {:error, :unsupported_format}

  @spec retry_or_return(atom(), String.t(), String.t(), keyword(), [String.t()]) ::
          {:ok, binary(), String.t()} | {:error, atom()}
  def retry_or_return(reason, executable, url, opts, rest) do
    if retryable_client_error?(reason) and rest != [] do
      try_clients(executable, url, opts, rest)
    else
      {:error, reason}
    end
  end

  @spec retryable_client_error?(atom()) :: boolean()
  def retryable_client_error?(reason) do
    case reason do
      :unsupported_format -> true
      :bot_check_challenge -> true
      :bot_reload_challenge -> true
      :resolver_failed -> true
      :resolver_timeout -> true
      :invalid_output -> true
      :resolver_outdated -> true
      :media_access_forbidden -> true
      :private_video -> false
      :not_live -> false
      :geo_blocked -> false
      :video_unavailable -> false
      _ -> false
    end
  end

  @spec selection(keyword()) :: String.t()
  def selection(opts) do
    case Keyword.get(opts, :format_id) do
      value when is_binary(value) and value != "" -> value
      value when is_integer(value) -> Integer.to_string(value)
      _ -> Keyword.get(opts, :quality_policy, "best[height<=1080]")
    end
  end

  @spec run(String.t(), [String.t()], keyword()) :: {:ok, binary()} | {:error, atom()}
  def run(executable, args, opts)
      when is_binary(executable) and is_list(args) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    launcher = Keyword.get(opts, :port_launcher, &default_port_launcher/2)

    case launch(launcher, executable, args) do
      {:ok, port} -> collect(port, timeout_ms)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec launch((String.t(), [String.t()] -> port()), String.t(), [String.t()]) ::
          {:ok, port()} | {:error, :resolver_failed}
  def launch(launcher, executable, args) when is_function(launcher, 2) do
    case launcher.(executable, args) do
      port when is_port(port) -> {:ok, port}
      _ -> {:error, :resolver_failed}
    end
  rescue
    ArgumentError -> {:error, :resolver_failed}
  end

  @spec default_port_launcher(String.t(), [String.t()]) :: port()
  def default_port_launcher(executable, args) when is_binary(executable) and is_list(args) do
    Port.open({:spawn_executable, String.to_charlist(executable)}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      :use_stdio,
      {:args, Enum.map(args, &String.to_charlist/1)}
    ])
  end

  @spec collect(port(), pos_integer()) :: {:ok, binary()} | {:error, atom()}
  def collect(port, timeout_ms)
      when is_port(port) and is_integer(timeout_ms) and timeout_ms > 0 do
    collect_output(port, <<>>, System.monotonic_time(:millisecond) + timeout_ms)
  end

  @spec collect_output(port(), binary(), integer()) :: {:ok, binary()} | {:error, atom()}
  def collect_output(port, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        collect_output(port, output <> chunk, deadline)

      {^port, {:exit_status, 0}} ->
        {:ok, output}

      {^port, {:exit_status, _status}} ->
        {:error, classify_error(output)}
    after
      remaining ->
        stop(port)
        {:error, :resolver_timeout}
    end
  end

  @spec stop(port()) :: :ok
  def stop(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) ->
        _ = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

    close_port(port)
  end

  @spec close_port(port()) :: :ok
  def close_port(port) when is_port(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  @spec parse_output(binary()) :: {:ok, String.t(), metadata()} | {:error, atom()}
  def parse_output(output) when is_binary(output) do
    lines = output |> String.split(["\r\n", "\n", "\r"]) |> Enum.map(&String.trim/1)

    with {:ok, resolved_url} <- find_resolved_url(lines),
         {:ok, metadata} <- find_metadata(lines, resolved_url) do
      {:ok, resolved_url, put_version(metadata, output)}
    else
      _ -> {:error, :invalid_output}
    end
  end

  @spec find_resolved_url([String.t()]) :: {:ok, String.t()} | {:error, :invalid_output}
  def find_resolved_url(lines) when is_list(lines) do
    case Enum.find(lines, &url_line?/1) do
      url when is_binary(url) ->
        if valid_media_url?(url), do: {:ok, url}, else: pipe_url(lines)

      _ ->
        pipe_url(lines)
    end
  end

  @spec pipe_url([String.t()]) :: {:ok, String.t()} | {:error, :invalid_output}
  def pipe_url(lines) do
    case Enum.find(lines, &(length(String.split(&1, "|")) >= 11)) do
      line when is_binary(line) ->
        url = line |> String.split("|", parts: 11) |> List.first()
        if valid_media_url?(url), do: {:ok, url}, else: {:error, :invalid_output}

      _ ->
        {:error, :invalid_output}
    end
  end

  @spec find_url([String.t()]) :: {:ok, String.t()} | {:error, :invalid_output}
  def find_url(lines) when is_list(lines) do
    case Enum.find(lines, &url_line?/1) do
      url when is_binary(url) ->
        if valid_media_url?(url), do: {:ok, url}, else: {:error, :invalid_output}

      _ ->
        {:error, :invalid_output}
    end
  end

  @spec find_metadata([String.t()], String.t()) :: {:ok, metadata()} | {:error, :invalid_output}
  def find_metadata(lines, resolved_url) when is_list(lines) and is_binary(resolved_url) do
    case Enum.find(lines, &metadata_line?/1) do
      line when is_binary(line) -> parse_metadata_line(line)
      _ -> parse_pipe_line(lines, resolved_url)
    end
  end

  @spec metadata_line?(String.t()) :: boolean()
  def metadata_line?(line) when is_binary(line) do
    String.starts_with?(line, "{") and String.ends_with?(line, "}")
  end

  @spec parse_metadata_line(String.t()) :: {:ok, metadata()} | {:error, :invalid_output}
  def parse_metadata_line(line) when is_binary(line) do
    case decode_metadata_json(line) do
      [
        id,
        is_live,
        format_id,
        duration,
        title,
        uploader,
        webpage_url,
        vbr,
        abr,
        tbr
      ] ->
        {:ok,
         metadata_map(%{
           id: id,
           live: parse_live(is_live),
           format_id: format_id,
           duration: duration,
           title: title,
           uploader: uploader,
           webpage_url: webpage_url,
           vbr: vbr,
           abr: abr,
           tbr: tbr
         })}

      _ ->
        {:error, :invalid_output}
    end
  end

  @spec parse_pipe_line([String.t()], String.t()) :: {:ok, metadata()} | {:error, :invalid_output}
  def parse_pipe_line(lines, _resolved_url) do
    case Enum.find(lines, &(length(String.split(&1, "|")) >= 11)) do
      line when is_binary(line) ->
        case String.split(line, "|", parts: 11) do
          [_url, is_live, live_status, format_id, vcodec, acodec, width, height, fps, _tbr, title] ->
            {:ok,
             metadata_map(%{
               id: "unknown",
               live: parse_live(is_live, live_status),
               format_id: format_id,
               title: title,
               vcodec: vcodec,
               acodec: acodec,
               width: width,
               height: height,
               fps: fps
             })}

          _ ->
            {:error, :invalid_output}
        end

      _ ->
        {:error, :invalid_output}
    end
  end

  @spec metadata_map(map()) :: metadata()
  def metadata_map(fields) when is_map(fields) do
    id = fields[:id] || "unknown"
    live = fields[:live] || false
    format_id = fields[:format_id]
    duration = fields[:duration]
    title = fields[:title]
    uploader = fields[:uploader]
    webpage_url = fields[:webpage_url]
    vcodec = fields[:vcodec]
    acodec = fields[:acodec]
    width = fields[:width]
    height = fields[:height]
    fps = fields[:fps]
    vbr = normalize_bitrate(fields[:vbr])
    abr = normalize_bitrate(fields[:abr])
    tbr = normalize_bitrate(fields[:tbr])

    media_info =
      %{
        "video" => video_info(vcodec, width, height, fps, vbr),
        "audio" => audio_info(acodec, abr),
        "duration" => normalize_value(duration),
        "title" => normalize_value(title),
        "uploader" => normalize_value(uploader),
        "format_id" => normalize_format(format_id)
      }
      |> maybe_put(:declared_bitrate_kbps, tbr)

    %{
      id: id,
      live: live,
      format_id: normalize_format(format_id),
      duration: normalize_value(duration),
      title: normalize_value(title),
      uploader: normalize_value(uploader),
      webpage_url: normalize_value(webpage_url),
      media_info: media_info,
      resolver_version: nil
    }
  end

  @spec video_info(term(), term(), term(), term(), number() | nil) :: map()
  def video_info(vcodec, width, height, fps, declared_bitrate_kbps) do
    %{
      "codec" => normalize_value(vcodec),
      "width" => parse_integer(width),
      "height" => parse_integer(height),
      "fps" => parse_number(fps)
    }
    |> maybe_put(:declared_bitrate_kbps, declared_bitrate_kbps)
  end

  @spec video_info(term(), term(), term(), term()) :: map()
  def video_info(vcodec, width, height, fps), do: video_info(vcodec, width, height, fps, nil)

  @spec audio_info(term(), number() | nil) :: map()
  def audio_info(acodec, declared_bitrate_kbps) do
    %{"codec" => normalize_value(acodec)}
    |> maybe_put(:declared_bitrate_kbps, declared_bitrate_kbps)
  end

  @spec audio_info(term()) :: map()
  def audio_info(acodec), do: audio_info(acodec, nil)

  @spec maybe_put(map(), atom(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, Atom.to_string(key), value)

  @spec put_version(metadata(), binary()) :: metadata()
  def put_version(metadata, output) when is_map(metadata) and is_binary(output) do
    version =
      case Regex.run(~r/yt-dlp(?: version)?\s+v?(\d{4}\.\d+\.\d+)/i, output,
             capture: :all_but_first
           ) do
        [value] ->
          value

        _ ->
          youtube_config = Application.get_env(:hydra_srt, :youtube, [])
          youtube_config[:yt_dlp_version] || System.get_env("YT_DLP_VERSION")
      end

    %{metadata | resolver_version: version}
  end

  @spec normalize_value(term()) :: String.t() | nil
  def normalize_value(value) when is_binary(value) and value not in ["", "NA", "N/A", "none"],
    do: value

  def normalize_value(value) when is_integer(value), do: Integer.to_string(value)
  def normalize_value(_value), do: nil

  @spec normalize_format(term()) :: String.t() | nil
  def normalize_format(value) do
    normalize_value(value)
  end

  @spec normalize_bitrate(term()) :: non_neg_integer() | nil
  def normalize_bitrate(value) do
    case parse_number(value) do
      number when is_number(number) and number >= 0 -> round(number)
      _ -> nil
    end
  end

  @spec parse_live(String.t()) :: boolean()
  def parse_live(value), do: parse_live(value, nil)

  @spec decode_metadata_json(String.t()) :: [term()] | :error
  defp decode_metadata_json(line) do
    case Jason.decode(line) do
      {:ok, %{"id" => id} = map} ->
        [
          id,
          map["is_live"],
          map["format_id"],
          map["duration"],
          map["title"],
          map["uploader"],
          map["webpage_url"],
          map["vbr"],
          map["abr"],
          map["tbr"]
        ]

      _ ->
        :error
    end
  end

  @spec parse_live(term(), term()) :: boolean()
  def parse_live(value, live_status) do
    # JSON gives a real boolean here, the pipe fallback gives a string.
    String.downcase(to_string(value)) == "true" or
      String.downcase(to_string(live_status)) in ["is_live", "live"]
  end

  @spec parse_integer(term()) :: integer() | nil
  def parse_integer(value) do
    case Integer.parse(to_string(value)) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  @spec parse_number(term()) :: number() | nil
  def parse_number(value) do
    case Integer.parse(to_string(value)) do
      {integer, ""} ->
        integer

      _ ->
        case Float.parse(to_string(value)) do
          {number, ""} -> number
          _ -> nil
        end
    end
  end

  @spec ensure_muxed(metadata()) :: :ok | {:error, :unsupported_format}
  def ensure_muxed(%{
        media_info: %{"video" => %{"codec" => video}, "audio" => %{"codec" => audio}}
      }) do
    cond do
      is_nil(video) and is_nil(audio) -> :ok
      is_binary(video) and is_binary(audio) -> :ok
      true -> {:error, :unsupported_format}
    end
  end

  def ensure_muxed(_metadata), do: :ok

  @spec ensure_fresh(metadata()) :: :ok | {:error, :resolver_outdated}
  def ensure_fresh(%{resolver_version: version}) when is_binary(version) do
    if stale_version?(version), do: {:error, :resolver_outdated}, else: :ok
  end

  def ensure_fresh(_metadata), do: :ok

  @spec stale_version?(String.t()) :: boolean()
  def stale_version?(version) when is_binary(version) do
    case Regex.run(~r/\A(\d{4})\.(\d+)\.(\d+)/, version, capture: :all_but_first) do
      [year, month, patch] ->
        with {year, ""} <- Integer.parse(year),
             {month, ""} <- Integer.parse(month),
             {patch, ""} <- Integer.parse(patch) do
          {year, month, patch} < {2024, 1, 1}
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  def stale_version?(_version), do: false

  @spec url_line?(String.t()) :: boolean()
  def url_line?(line) when is_binary(line) do
    String.starts_with?(line, "http://") or String.starts_with?(line, "https://")
  end

  @spec valid_media_url?(String.t()) :: boolean()
  def valid_media_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) -> true
      %URI{scheme: "http", host: host} when is_binary(host) -> loopback_host?(host)
      _ -> false
    end
  end

  def valid_media_url?(_url), do: false

  @spec loopback_host?(String.t()) :: boolean()
  def loopback_host?(host) when is_binary(host) do
    downcased = String.downcase(host)
    downcased == "localhost" or downcased == "::1" or String.starts_with?(downcased, "127.")
  end

  @spec classify_error(binary()) :: atom()
  def classify_error(output) when is_binary(output) do
    message = String.downcase(output)

    cond do
      String.contains?(message, "sign in to confirm you're not a bot") ->
        :bot_check_challenge

      String.contains?(message, "the page needs to be reloaded") ->
        :bot_reload_challenge

      (String.contains?(message, "requested format") and
         String.contains?(message, "not available")) or
          String.contains?(message, "no video formats found") ->
        :unsupported_format

      String.contains?(message, "private") or
        String.contains?(message, "members-only") or
        String.contains?(message, "age-restricted") or
          String.contains?(message, "age-gated") ->
        :private_video

      String.contains?(message, "will begin") or
        String.contains?(message, "not live yet") or
          String.contains?(message, "live stream has ended") ->
        :not_live

      String.contains?(message, "in your country") or
          String.contains?(message, "geo") ->
        :geo_blocked

      String.contains?(message, "video is unavailable") or
          String.contains?(message, "does not exist") ->
        :video_unavailable

      String.contains?(message, "please update yt-dlp") or
          (String.contains?(message, "extractor") and String.contains?(message, "update")) ->
        :resolver_outdated

      String.contains?(message, "http error 403 forbidden") and
          String.contains?(message, "segment") ->
        :media_access_forbidden

      String.contains?(message, "timed out") or String.contains?(message, "timeout") ->
        :resolver_timeout

      true ->
        :resolver_failed
    end
  end
end

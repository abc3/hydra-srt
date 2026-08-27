defmodule HydraSrt.TestSupport.YoutubeHarness do
  @moduledoc "Composition helpers for the opt-in full YouTube-source E2E tests."

  alias HydraSrt.TestSupport.FakeYtDlp
  alias HydraSrt.TestSupport.HlsGenerator
  alias HydraSrt.TestSupport.HlsServer

  @type handle :: %{
          generator: HlsGenerator.handle(),
          server: HlsServer.handle(),
          resolver: String.t(),
          playlist_url: String.t()
        }

  @spec start(keyword()) :: {:ok, handle()} | {:error, term()}
  def start(opts \\ []) when is_list(opts) do
    case HlsGenerator.start(opts) do
      {:ok, generator} ->
        case HlsServer.start(HlsGenerator.directory(generator), opts) do
          {:ok, server} ->
            variant = Keyword.get(opts, :resolver_variant, :live)
            playlist_url = HlsServer.playlist_url(server)
            resolver = FakeYtDlp.configure!(variant, playlist_url, opts)

            {:ok,
             %{
               generator: generator,
               server: server,
               resolver: resolver,
               playlist_url: playlist_url
             }}

          {:error, _reason} = error ->
            HlsGenerator.stop(generator)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec stop(handle()) :: :ok
  def stop(%{generator: generator, server: server}) do
    HlsServer.stop(server)
    HlsGenerator.stop(generator)
    :ok
  end

  @spec set_http_behavior(handle(), HlsServer.behavior()) :: :ok
  def set_http_behavior(%{server: server}, behavior), do: HlsServer.set_behavior(server, behavior)

  @spec compose_route!(String.t(), String.t(), keyword()) :: map()
  def compose_route!(base_url, token, opts)
      when is_binary(base_url) and is_binary(token) and is_list(opts) do
    fixture = start_fixture!(opts)
    route_params = Keyword.get(opts, :route, %{})
    source_params = Keyword.get(opts, :source, %{})
    destination_params = Keyword.get(opts, :destination, %{})
    route = HydraSrt.TestSupport.E2EHelpers.api_create_route!(base_url, token, route_params)

    source =
      %{
        "schema" => "YOUTUBE",
        "youtube_url" => "https://www.youtube.com/watch?v=test-fixture",
        "youtube_quality_policy" => "best[height<=720]",
        "youtube_end_action" => "stop"
      }
      |> Map.merge(source_params)

    :ok = HydraSrt.TestSupport.E2EHelpers.api_create_source!(base_url, token, route, source)

    destination_port =
      Keyword.get(destination_params, "port", HydraSrt.TestSupport.E2EHelpers.udp_free_port!())

    destination =
      %{
        "schema" => "UDP",
        "host" => "127.0.0.1",
        "port" => destination_port
      }
      |> Map.merge(destination_params)

    :ok =
      HydraSrt.TestSupport.E2EHelpers.api_create_destination!(base_url, token, route, destination)

    :ok = HydraSrt.TestSupport.E2EHelpers.api_start_route!(base_url, token, route)

    Map.merge(fixture, %{
      route_id: route,
      destination: destination,
      output_url: "udp://127.0.0.1:#{destination_port}"
    })
  end

  @spec start_fixture!(keyword()) :: handle()
  def start_fixture!(opts) do
    case start(opts) do
      {:ok, handle} -> handle
      {:error, reason} -> raise "could not start YouTube fixture: #{inspect(reason)}"
    end
  end

  @spec probe!(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def probe!(url, opts \\ []) when is_binary(url) and is_list(opts) do
    HydraSrt.TestSupport.E2EHelpers.ffprobe_streams(
      url,
      Keyword.get(opts, :timeout_ms, 5_000),
      opts
    )
  end

  @spec assert_stream!(String.t(), keyword()) :: [map()]
  def assert_stream!(url, opts \\ []) when is_binary(url) and is_list(opts) do
    {:ok, streams} = probe!(url, opts)
    expected_width = Keyword.get(opts, :width)
    expected_height = Keyword.get(opts, :height)
    expected_fps = Keyword.get(opts, :fps)

    true = Enum.any?(streams, &video_matches?(&1, expected_width, expected_height, expected_fps))
    true = Enum.any?(streams, &(&1["codec_type"] == "audio" and &1["codec_name"] == "aac"))
    streams
  end

  @spec video_matches?(map(), integer() | nil, integer() | nil, number() | nil) :: boolean()
  def video_matches?(stream, width, height, fps) do
    stream["codec_type"] == "video" and
      (is_nil(width) or stream["width"] == width) and
      (is_nil(height) or stream["height"] == height) and
      (is_nil(fps) or frame_rate(stream["r_frame_rate"]) == fps)
  end

  @spec frame_rate(String.t() | nil) :: float() | nil
  def frame_rate(nil), do: nil

  def frame_rate(rate) when is_binary(rate) do
    case String.split(rate, "/") do
      [numerator, denominator] ->
        with {n, ""} <- Integer.parse(numerator),
             {d, ""} <- Integer.parse(denominator),
             true <- d != 0 do
          n / d
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end
end

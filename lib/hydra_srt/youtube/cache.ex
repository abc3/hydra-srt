defmodule HydraSrt.Youtube.Cache do
  @moduledoc "Cachex-backed YouTube resolution cache and retry guard."

  @cache HydraSrt.Cache
  @floor_ms :timer.seconds(30)
  @negative_ttl_ms :timer.minutes(1)
  @max_negative_ttl_ms :timer.minutes(10)
  @default_ttl_ms :timer.minutes(30)
  @safety_margin_ms :timer.minutes(10)

  @type key :: tuple()
  @type entry :: %{
          result: tuple(),
          cached_at_ms: integer(),
          failure_count: non_neg_integer(),
          key: key()
        }

  @spec get(String.t(), keyword()) :: {:hit, tuple()} | :miss | {:blocked, tuple()}
  def get(video_id, opts) when is_binary(video_id) and is_list(opts) do
    key = key(video_id, opts)

    case cache_get(key) do
      %{result: result} ->
        {:hit, result}

      _ ->
        case cache_get(floor_key(video_id)) do
          %{result: result, key: ^key} -> {:blocked, result}
          %{result: _result} -> {:blocked, {:error, :resolve_rate_limited}}
          _ -> :miss
        end
    end
  end

  @spec put(String.t(), keyword(), tuple(), String.t() | nil) :: :ok
  def put(video_id, opts, result, resolved_url)
      when is_binary(video_id) and is_list(opts) and is_tuple(result) do
    now = System.monotonic_time(:millisecond)
    key = key(video_id, opts)
    previous = cache_get(key)
    failure_count = failure_count(previous, result)
    ttl = ttl_for(result, resolved_url, failure_count)
    entry = %{result: result, cached_at_ms: now, failure_count: failure_count, key: key}

    cache_put(key, entry, ttl)
    cache_put(floor_key(video_id), entry, @floor_ms)
    cache_index_put(video_id, key)
    :ok
  end

  @spec invalidate(String.t()) :: :ok
  def invalidate(video_id) when is_binary(video_id) do
    keys = cache_get(index_key(video_id)) || []
    Enum.each(keys, &cache_delete/1)
    cache_delete(floor_key(video_id))
    cache_delete(index_key(video_id))
    :ok
  end

  @spec key(String.t(), keyword()) :: key()
  def key(video_id, opts) do
    {:youtube_resolution, video_id, normalize_option(Keyword.get(opts, :format_id)),
     normalize_option(Keyword.get(opts, :quality_policy))}
  end

  @spec floor_key(String.t()) :: key()
  def floor_key(video_id), do: {:youtube_resolution_floor, video_id}

  @spec index_key(String.t()) :: key()
  def index_key(video_id), do: {:youtube_resolution_index, video_id}

  @spec ttl_ms(String.t() | nil, integer()) :: pos_integer()
  def ttl_ms(url, now_seconds \\ System.system_time(:second)) do
    case expires_at(url) do
      expire when is_integer(expire) ->
        max(@floor_ms, (expire - now_seconds) * 1_000 - @safety_margin_ms)

      _ ->
        @default_ttl_ms
    end
  end

  @spec expires_at(String.t() | nil) :: integer() | nil
  def expires_at(url) when is_binary(url) do
    case Regex.run(~r/(?:\?|&)expire=(\d+)/, url, capture: :all_but_first) do
      [value] ->
        case Integer.parse(value) do
          {expire, ""} -> expire
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def expires_at(_url), do: nil

  @spec failure_count(entry() | nil, tuple()) :: non_neg_integer()
  def failure_count(%{failure_count: count}, {:error, _reason}) when is_integer(count),
    do: count + 1

  def failure_count(_previous, {:error, _reason}), do: 1
  def failure_count(_previous, _result), do: 0

  @spec ttl_for(tuple(), String.t() | nil, non_neg_integer()) :: pos_integer()
  def ttl_for({:ok, _media}, url, _failure_count), do: ttl_ms(url)

  def ttl_for({:error, _reason}, _url, failure_count) do
    multiplier = Integer.pow(2, min(max(failure_count - 1, 0), 3))
    min(@max_negative_ttl_ms, @negative_ttl_ms * multiplier)
  end

  @spec normalize_option(term()) :: String.t()
  def normalize_option(value) when is_binary(value), do: value
  def normalize_option(value) when is_integer(value), do: Integer.to_string(value)
  def normalize_option(_value), do: ""

  @spec cache_get(key()) :: term() | nil
  def cache_get(key) do
    case Process.whereis(@cache) do
      pid when is_pid(pid) ->
        case Cachex.get(@cache, key) do
          {:ok, value} -> value
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @spec cache_put(key(), term(), pos_integer()) :: :ok
  def cache_put(key, value, ttl) do
    if Process.whereis(@cache) do
      _ = Cachex.put(@cache, key, value, ttl: ttl)
    end

    :ok
  end

  @spec cache_delete(key()) :: :ok
  def cache_delete(key) do
    if Process.whereis(@cache) do
      _ = Cachex.del(@cache, key)
    end

    :ok
  end

  @spec cache_index_put(String.t(), key()) :: :ok
  def cache_index_put(video_id, key) do
    index =
      case cache_get(index_key(video_id)) do
        keys when is_list(keys) -> Enum.uniq([key | keys])
        _ -> [key]
      end

    cache_put(index_key(video_id), index, @max_negative_ttl_ms)
  end
end

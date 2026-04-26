defmodule HydraSrt.Stats.Analytics do
  @moduledoc false

  @window_to_seconds %{
    "last_30_min" => 30 * 60,
    "last_hour" => 60 * 60,
    "last_6_hour" => 6 * 60 * 60,
    "last_24_hour" => 24 * 60 * 60
  }

  @bucket_10_seconds_ms 10_000
  @bucket_30_seconds_ms 30_000
  @bucket_1_minute_ms 60_000
  @bucket_5_minutes_ms 300_000

  @type query_params :: %{
          required(:from) => DateTime.t(),
          required(:to) => DateTime.t(),
          required(:window) => binary(),
          required(:bucket_ms) => pos_integer()
        }

  @spec build_query_params(map()) :: {:ok, query_params()} | {:error, {:bad_request, binary()}}
  def build_query_params(params) when is_map(params) do
    with {:ok, range} <- parse_range(params),
         {:ok, bucket_ms} <- bucket_ms_for_range(range.from, range.to) do
      {:ok,
       %{
         from: range.from,
         to: range.to,
         window: range.window,
         bucket_ms: bucket_ms
       }}
    end
  end

  @spec fetch_route_timeseries(binary(), query_params(), GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def fetch_route_timeseries(route_id, query_params, conn \\ HydraSrt.AnalyticsConn)
      when is_binary(route_id) and is_map(query_params) do
    sql = """
    WITH sampled AS (
      SELECT
        to_timestamp(FLOOR(epoch_ms(ts)::DOUBLE / ?) * ? / 1000.0) AS bucket_ts,
        entity_type,
        entity_id,
        avg(value_double) AS metric_value
      FROM stats_samples
      WHERE route_id = ?
        AND metric_key IN ('bytes_in_per_sec', 'bytes_out_per_sec')
        AND ts >= CAST(? AS TIMESTAMP)
        AND ts <= CAST(? AS TIMESTAMP)
      GROUP BY 1, 2, 3
    )
    SELECT bucket_ts, entity_type, entity_id, metric_value
    FROM sampled
    ORDER BY bucket_ts ASC, entity_type ASC, entity_id ASC
    """

    params = [
      query_params.bucket_ms,
      query_params.bucket_ms,
      route_id,
      DateTime.to_iso8601(query_params.from),
      DateTime.to_iso8601(query_params.to)
    ]

    case Adbc.Connection.query(conn, sql, params) do
      {:ok, result} ->
        rows = result |> Adbc.Result.to_map() |> rows_from_columns()

        {:ok,
         %{
           points: points_from_rows(rows),
           meta: %{
             from: DateTime.to_iso8601(query_params.from),
             to: DateTime.to_iso8601(query_params.to),
             window: query_params.window,
             bucket_ms: query_params.bucket_ms
           }
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec parse_range(map()) ::
          {:ok, %{from: DateTime.t(), to: DateTime.t(), window: binary()}}
          | {:error, {:bad_request, binary()}}
  def parse_range(params) when is_map(params) do
    from_raw = Map.get(params, "from")
    to_raw = Map.get(params, "to")

    cond do
      is_binary(from_raw) and is_binary(to_raw) ->
        with {:ok, from_dt} <- parse_datetime(from_raw),
             {:ok, to_dt} <- parse_datetime(to_raw),
             :ok <- validate_range_order(from_dt, to_dt) do
          {:ok, %{from: from_dt, to: to_dt, window: "custom"}}
        end

      true ->
        window = Map.get(params, "window", "last_hour")

        case Map.fetch(@window_to_seconds, window) do
          {:ok, seconds} ->
            to_dt = DateTime.utc_now()
            from_dt = DateTime.add(to_dt, -seconds, :second)
            {:ok, %{from: from_dt, to: to_dt, window: window}}

          :error ->
            {:error,
             {:bad_request,
              "Invalid window. Allowed: last_30_min, last_hour, last_6_hour, last_24_hour"}}
        end
    end
  end

  @spec parse_datetime(binary()) :: {:ok, DateTime.t()} | {:error, {:bad_request, binary()}}
  def parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      {:error, _reason} ->
        {:error, {:bad_request, "Invalid datetime format. Use ISO8601"}}
    end
  end

  @spec validate_range_order(DateTime.t(), DateTime.t()) ::
          :ok | {:error, {:bad_request, binary()}}
  def validate_range_order(from_dt, to_dt) do
    if DateTime.compare(from_dt, to_dt) == :lt do
      :ok
    else
      {:error, {:bad_request, "Invalid range: from must be earlier than to"}}
    end
  end

  @spec bucket_ms_for_range(DateTime.t(), DateTime.t()) ::
          {:ok, pos_integer()} | {:error, {:bad_request, binary()}}
  def bucket_ms_for_range(from_dt, to_dt) do
    range_seconds = DateTime.diff(to_dt, from_dt, :second)

    if range_seconds <= 0 do
      {:error, {:bad_request, "Invalid range: from must be earlier than to"}}
    else
      cond do
        range_seconds <= 60 * 60 -> {:ok, @bucket_10_seconds_ms}
        range_seconds <= 6 * 60 * 60 -> {:ok, @bucket_30_seconds_ms}
        range_seconds <= 24 * 60 * 60 -> {:ok, @bucket_1_minute_ms}
        true -> {:ok, @bucket_5_minutes_ms}
      end
    end
  end

  @spec rows_from_columns(map()) :: [map()]
  def rows_from_columns(columns) when is_map(columns) do
    length =
      columns
      |> Map.values()
      |> List.first([])
      |> Kernel.length()

    if length == 0 do
      []
    else
      Enum.map(0..(length - 1), fn index ->
        %{
          bucket_ts: value_at(columns, "bucket_ts", index),
          entity_type: value_at(columns, "entity_type", index),
          entity_id: value_at(columns, "entity_id", index),
          metric_value: value_at(columns, "metric_value", index)
        }
      end)
      |> Enum.reject(&is_nil(&1.bucket_ts))
    end
  end

  @spec value_at(map(), binary(), integer()) :: term()
  def value_at(columns, key, index)
      when is_map(columns) and is_binary(key) and is_integer(index) do
    columns
    |> Map.get(key, [])
    |> Enum.at(index)
  end

  @spec points_from_rows([map()]) :: [map()]
  def points_from_rows(rows) when is_list(rows) do
    rows
    |> Enum.reduce(%{}, fn row, acc ->
      timestamp = normalize_timestamp(row.bucket_ts)
      current = Map.get(acc, timestamp, %{timestamp: timestamp, source: nil, destinations: %{}})
      metric_value = number_or_nil(row.metric_value)

      updated =
        case row.entity_type do
          "source" ->
            %{current | source: metric_value}

          "destination" ->
            destination_id = row.entity_id

            if is_binary(destination_id) and destination_id != "" do
              %{
                current
                | destinations: Map.put(current.destinations, destination_id, metric_value)
              }
            else
              current
            end

          _ ->
            current
        end

      Map.put(acc, timestamp, updated)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.timestamp)
  end

  @spec normalize_timestamp(term()) :: binary()
  def normalize_timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)

  def normalize_timestamp(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  def normalize_timestamp(value), do: to_string(value)

  @spec number_or_nil(term()) :: float() | nil
  def number_or_nil(value) when is_integer(value), do: value * 1.0
  def number_or_nil(value) when is_float(value), do: value
  def number_or_nil(_value), do: nil
end

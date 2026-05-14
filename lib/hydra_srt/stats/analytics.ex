defmodule HydraSrt.Stats.Analytics do
  @moduledoc false
  alias HydraSrt.Db

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
  @bucket_15_minutes_ms 900_000
  @bucket_30_minutes_ms 1_800_000
  @bucket_1_hour_ms 3_600_000
  @default_max_points 300
  @min_max_points 50
  @max_max_points 2_000

  @type query_params :: %{
          required(:from) => DateTime.t(),
          required(:to) => DateTime.t(),
          required(:window) => binary(),
          required(:bucket_ms) => pos_integer()
        }

  @spec build_query_params(map()) :: {:ok, query_params()} | {:error, {:bad_request, binary()}}
  def build_query_params(params) when is_map(params) do
    max_points = parse_max_points(Map.get(params, "max_points"), @default_max_points)

    with {:ok, range} <- parse_range(params),
         {:ok, bucket_ms} <- bucket_ms_for_range(range.from, range.to, max_points) do
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
        switches = fetch_route_switches(route_id, query_params, conn)
        initial_source_id = fetch_last_source_before_window(route_id, query_params, conn)
        srt_quality = fetch_route_srt_quality(route_id, query_params, conn)

        {:ok,
         %{
           points: points_from_rows(rows),
           switches: switches,
           source_timeline:
             source_timeline_from_switches(switches, query_params, initial_source_id),
           srt_quality: srt_quality,
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

  @spec fetch_node_timeseries(binary(), query_params(), GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def fetch_node_timeseries(node_id, query_params, conn \\ HydraSrt.AnalyticsConn)
      when is_binary(node_id) and is_map(query_params) do
    node_netif_prefix = "#{node_id}:%"

    sql = """
    WITH sampled AS (
      SELECT
        to_timestamp(FLOOR(epoch_ms(ts)::DOUBLE / ?) * ? / 1000.0) AS bucket_ts,
        entity_type,
        entity_id,
        metric_key,
        avg(value_double) AS metric_value
      FROM stats_samples
      WHERE route_id IS NULL
        AND (
          (entity_type = 'node' AND entity_id = ? AND metric_key IN ('cpu_util', 'ram_usage', 'swap_usage', 'cpu_la_avg1', 'cpu_la_avg5', 'cpu_la_avg15'))
          OR
          (entity_type = 'net_if' AND entity_id LIKE ? AND metric_key IN ('net_rx_bytes_per_sec', 'net_tx_bytes_per_sec'))
        )
        AND ts >= CAST(? AS TIMESTAMP)
        AND ts <= CAST(? AS TIMESTAMP)
      GROUP BY 1, 2, 3, 4
    )
    SELECT bucket_ts, entity_type, entity_id, metric_key, metric_value
    FROM sampled
    ORDER BY bucket_ts ASC, entity_type ASC, entity_id ASC, metric_key ASC
    """

    params = [
      query_params.bucket_ms,
      query_params.bucket_ms,
      node_id,
      node_netif_prefix,
      DateTime.to_iso8601(query_params.from),
      DateTime.to_iso8601(query_params.to)
    ]

    case Adbc.Connection.query(conn, sql, params) do
      {:ok, result} ->
        rows = result |> Adbc.Result.to_map() |> node_rows_from_columns()

        {:ok,
         %{
           points: node_points_from_rows(rows),
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

  @spec fetch_route_events(binary(), map(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def fetch_route_events(route_id, params, conn \\ HydraSrt.AnalyticsConn)
      when is_binary(route_id) and is_map(params) do
    limit = parse_int_param(Map.get(params, "limit"), 100)
    offset = parse_int_param(Map.get(params, "offset"), 0)
    type_filter = Map.get(params, "type")

    with {:ok, range} <- parse_range(params) do
      sql = """
      SELECT ts, route_id, event_type, severity, source_id, from_source_id, to_source_id, reason, message, details_json
      FROM events
      WHERE route_id = ?
        AND ts >= CAST(? AS TIMESTAMP)
        AND ts <= CAST(? AS TIMESTAMP)
        AND (? IS NULL OR event_type = ?)
      ORDER BY ts DESC
      LIMIT ?
      OFFSET ?
      """

      query_params = [
        route_id,
        DateTime.to_iso8601(range.from),
        DateTime.to_iso8601(range.to),
        type_filter,
        type_filter,
        limit,
        offset
      ]

      case Adbc.Connection.query(conn, sql, query_params) do
        {:ok, result} ->
          rows = result |> Adbc.Result.to_map() |> event_rows_from_columns()
          total = fetch_route_events_total(route_id, range, type_filter, conn)

          {:ok,
           %{
             events: rows,
             meta: %{
               from: DateTime.to_iso8601(range.from),
               to: DateTime.to_iso8601(range.to),
               window: range.window,
               limit: limit,
               offset: offset,
               type: type_filter,
               total: total
             }
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec fetch_routes_status_timeseries(query_params(), GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def fetch_routes_status_timeseries(query_params, conn \\ HydraSrt.AnalyticsConn)
      when is_map(query_params) do
    with {:ok, routes} <- Db.get_all_routes(false),
         {:ok, seed_rows} <- fetch_route_status_seed_rows(query_params, conn),
         {:ok, event_rows} <- fetch_route_status_event_rows(query_params, conn) do
      route_statuses = initial_route_statuses(routes, seed_rows)

      points =
        build_route_status_points(
          route_statuses,
          event_rows,
          query_params.from,
          query_params.to,
          query_params.bucket_ms
        )

      {:ok,
       %{
         points: points,
         meta: %{
           from: DateTime.to_iso8601(query_params.from),
           to: DateTime.to_iso8601(query_params.to),
           window: query_params.window,
           bucket_ms: query_params.bucket_ms
         }
       }}
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

  @spec bucket_ms_for_range(DateTime.t(), DateTime.t(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, {:bad_request, binary()}}
  def bucket_ms_for_range(from_dt, to_dt, max_points \\ @default_max_points) do
    range_seconds = DateTime.diff(to_dt, from_dt, :second)

    if range_seconds <= 0 do
      {:error, {:bad_request, "Invalid range: from must be earlier than to"}}
    else
      normalized_max_points = parse_max_points(max_points, @default_max_points)
      range_ms = range_seconds * 1_000
      raw_bucket_ms = ceil(range_ms / normalized_max_points)
      {:ok, normalize_bucket_ms(raw_bucket_ms)}
    end
  end

  defp normalize_bucket_ms(raw_bucket_ms) when is_integer(raw_bucket_ms) and raw_bucket_ms > 0 do
    [
      @bucket_10_seconds_ms,
      @bucket_30_seconds_ms,
      @bucket_1_minute_ms,
      @bucket_5_minutes_ms,
      @bucket_15_minutes_ms,
      @bucket_30_minutes_ms,
      @bucket_1_hour_ms
    ]
    |> Enum.find(@bucket_1_hour_ms, fn bucket -> bucket >= raw_bucket_ms end)
  end

  defp parse_max_points(nil, default), do: default

  defp parse_max_points(value, _default) when is_integer(value) do
    value
    |> max(@min_max_points)
    |> min(@max_max_points)
  end

  defp parse_max_points(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} ->
        parse_max_points(parsed, default)

      _ ->
        default
    end
  end

  defp parse_max_points(_value, default), do: default

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

  @spec fetch_route_switches(binary(), query_params(), GenServer.server()) :: [map()]
  def fetch_route_switches(route_id, query_params, conn)
      when is_binary(route_id) and is_map(query_params) do
    sql = """
    SELECT ts, from_source_id, to_source_id, reason
    FROM events
    WHERE route_id = ?
      AND event_type = 'source_switch'
      AND ts >= CAST(? AS TIMESTAMP)
      AND ts <= CAST(? AS TIMESTAMP)
    ORDER BY ts ASC
    """

    params = [
      route_id,
      DateTime.to_iso8601(query_params.from),
      DateTime.to_iso8601(query_params.to)
    ]

    case Adbc.Connection.query(conn, sql, params) do
      {:ok, result} ->
        result
        |> Adbc.Result.to_map()
        |> switch_rows_from_columns()

      {:error, _reason} ->
        []
    end
  end

  @spec source_timeline_from_switches([map()], query_params()) :: [map()]
  def source_timeline_from_switches(switches, query_params),
    do: source_timeline_from_switches(switches, query_params, nil)

  @spec source_timeline_from_switches([map()], query_params(), binary() | nil) :: [map()]
  def source_timeline_from_switches([], query_params, initial_source_id)
      when is_map(query_params) and is_binary(initial_source_id) do
    [
      %{
        "from" => normalize_timestamp(query_params.from),
        "to" => DateTime.to_iso8601(query_params.to),
        "source_id" => initial_source_id
      }
    ]
  end

  def source_timeline_from_switches([], _query_params, _initial_source_id), do: []

  def source_timeline_from_switches(switches, query_params, initial_source_id)
      when is_list(switches) and is_map(query_params) do
    inferred_from =
      case List.first(switches) do
        %{"ts" => ts} -> ts
        _ -> query_params.to
      end

    from_ts = Map.get(query_params, :from, inferred_from) |> normalize_timestamp()
    to_ts = DateTime.to_iso8601(query_params.to)
    first_switch = List.first(switches) || %{}

    first_source =
      initial_source_id || Map.get(first_switch, "from_source_id") ||
        Map.get(first_switch, "to_source_id")

    {segments, _current_from, _current_source} =
      Enum.reduce(switches, {[], from_ts, first_source}, fn switch,
                                                            {segments, current_from,
                                                             current_source} ->
        ts = Map.get(switch, "ts") |> normalize_timestamp()
        to_source = Map.get(switch, "to_source_id")

        cond do
          is_nil(current_source) ->
            {segments, ts, to_source}

          current_source != to_source ->
            next_segment = %{"from" => current_from, "to" => ts, "source_id" => current_source}
            {[next_segment | segments], ts, to_source}

          true ->
            {segments, current_from, current_source}
        end
      end)

    last_switch = List.last(switches) || %{}

    end_segment =
      case last_switch do
        %{"to_source_id" => source_id} when is_binary(source_id) ->
          [
            %{
              "from" => normalize_timestamp(Map.get(last_switch, "ts")),
              "to" => to_ts,
              "source_id" => source_id
            }
          ]

        _ ->
          []
      end

    (Enum.reverse(segments) ++ end_segment)
    |> Enum.reject(fn segment -> is_nil(segment["source_id"]) end)
  end

  defp fetch_last_source_before_window(route_id, query_params, conn) do
    sql = """
    SELECT to_source_id
    FROM events
    WHERE route_id = ?
      AND event_type = 'source_switch'
      AND ts < CAST(? AS TIMESTAMP)
    ORDER BY ts DESC
    LIMIT 1
    """

    params = [route_id, DateTime.to_iso8601(query_params.from)]

    case Adbc.Connection.query(conn, sql, params) do
      {:ok, result} ->
        result
        |> Adbc.Result.to_map()
        |> Map.get("to_source_id", [])
        |> List.first()

      {:error, _reason} ->
        nil
    end
  end

  defp event_rows_from_columns(columns) when is_map(columns) do
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
          "ts" => normalize_timestamp(value_at(columns, "ts", index)),
          "route_id" => value_at(columns, "route_id", index),
          "event_type" => value_at(columns, "event_type", index),
          "severity" => value_at(columns, "severity", index),
          "source_id" => value_at(columns, "source_id", index),
          "from_source_id" => value_at(columns, "from_source_id", index),
          "to_source_id" => value_at(columns, "to_source_id", index),
          "reason" => value_at(columns, "reason", index),
          "message" => value_at(columns, "message", index),
          "details_json" => value_at(columns, "details_json", index)
        }
      end)
      |> Enum.reject(&is_nil(&1["ts"]))
    end
  end

  defp switch_rows_from_columns(columns) when is_map(columns) do
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
          "ts" => normalize_timestamp(value_at(columns, "ts", index)),
          "from_source_id" => value_at(columns, "from_source_id", index),
          "to_source_id" => value_at(columns, "to_source_id", index),
          "reason" => value_at(columns, "reason", index)
        }
      end)
      |> Enum.reject(&is_nil(&1["ts"]))
    end
  end

  defp parse_int_param(nil, default), do: default

  defp parse_int_param(value, _default) when is_integer(value) and value >= 0, do: value

  defp parse_int_param(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp parse_int_param(_value, default), do: default

  defp fetch_route_status_seed_rows(query_params, conn) do
    sql = """
    WITH ranked AS (
      SELECT
        route_id,
        ts,
        details_json,
        ROW_NUMBER() OVER (PARTITION BY route_id ORDER BY ts DESC) AS rn
      FROM events
      WHERE event_type = 'route_status_change'
        AND ts < CAST(? AS TIMESTAMP)
    )
    SELECT route_id, ts, details_json
    FROM ranked
    WHERE rn = 1
    ORDER BY route_id ASC
    """

    params = [DateTime.to_iso8601(query_params.from)]

    case Adbc.Connection.query(conn, sql, params) do
      {:ok, result} ->
        {:ok,
         route_status_rows_from_columns(
           Adbc.Result.to_map(result),
           &extract_new_status_from_details/1
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_route_status_event_rows(query_params, conn) do
    sql = """
    SELECT route_id, ts, details_json
    FROM events
    WHERE event_type = 'route_status_change'
      AND ts >= CAST(? AS TIMESTAMP)
      AND ts <= CAST(? AS TIMESTAMP)
    ORDER BY ts ASC, route_id ASC
    """

    params = [
      DateTime.to_iso8601(query_params.from),
      DateTime.to_iso8601(query_params.to)
    ]

    case Adbc.Connection.query(conn, sql, params) do
      {:ok, result} ->
        {:ok,
         route_status_rows_from_columns(
           Adbc.Result.to_map(result),
           &extract_new_status_from_details/1
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp route_status_rows_from_columns(columns, status_parser)
       when is_map(columns) and is_function(status_parser, 1) do
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
          "route_id" => value_at(columns, "route_id", index),
          "ts_ms" => value_at(columns, "ts", index) |> timestamp_to_ms(),
          "status" => value_at(columns, "details_json", index) |> status_parser.()
        }
      end)
      |> Enum.reject(fn row ->
        is_nil(row["route_id"]) or is_nil(row["ts_ms"]) or is_nil(row["status"])
      end)
    end
  end

  defp initial_route_statuses(routes, seed_rows) when is_list(routes) and is_list(seed_rows) do
    base =
      Enum.reduce(routes, %{}, fn route, acc ->
        route_id = route["id"]
        status = normalize_route_status(route["schema_status"] || route["status"] || "stopped")
        Map.put(acc, route_id, status)
      end)

    Enum.reduce(seed_rows, base, fn row, acc ->
      Map.put(acc, row["route_id"], normalize_route_status(row["status"]))
    end)
  end

  defp build_route_status_points(route_statuses, event_rows, from_dt, to_dt, bucket_ms)
       when is_map(route_statuses) and is_list(event_rows) and is_integer(bucket_ms) and
              bucket_ms > 0 do
    from_ms = DateTime.to_unix(from_dt, :millisecond)
    to_ms = DateTime.to_unix(to_dt, :millisecond)
    start_ms = ceil_ts_to_bucket(from_ms, bucket_ms)
    end_ms = ceil_ts_to_bucket(to_ms, bucket_ms)
    sorted_events = Enum.sort_by(event_rows, & &1["ts_ms"])

    if start_ms > end_ms do
      []
    else
      {points_reversed, _statuses, _events_left} =
        Enum.reduce(
          start_ms..end_ms//bucket_ms,
          {[], route_statuses, sorted_events},
          fn bucket_ts_ms, {points, statuses, events_left} ->
            apply_until_ms = min(bucket_ts_ms, to_ms)

            {updated_statuses, remaining_events} =
              apply_events_until_bucket(statuses, events_left, apply_until_ms)

            point =
              updated_statuses
              |> status_counts()
              |> Map.put(:timestamp, ms_to_iso8601(apply_until_ms))

            {[point | points], updated_statuses, remaining_events}
          end
        )

      Enum.reverse(points_reversed)
    end
  end

  defp apply_events_until_bucket(statuses, events, bucket_ts_ms) do
    do_apply_events_until_bucket(statuses, events, bucket_ts_ms)
  end

  defp do_apply_events_until_bucket(statuses, [], _bucket_ts_ms), do: {statuses, []}

  defp do_apply_events_until_bucket(statuses, [event | rest], bucket_ts_ms) do
    if event["ts_ms"] <= bucket_ts_ms do
      next_statuses =
        Map.put(statuses, event["route_id"], normalize_route_status(event["status"]))

      do_apply_events_until_bucket(next_statuses, rest, bucket_ts_ms)
    else
      {statuses, [event | rest]}
    end
  end

  defp status_counts(statuses) when is_map(statuses) do
    Enum.reduce(
      statuses,
      %{
        processing: 0,
        starting: 0,
        reconnecting: 0,
        restarting: 0,
        failed: 0,
        stopped: 0,
        other: 0
      },
      fn
        {_route_id, "processing"}, acc -> Map.update!(acc, :processing, &(&1 + 1))
        {_route_id, "starting"}, acc -> Map.update!(acc, :starting, &(&1 + 1))
        {_route_id, "reconnecting"}, acc -> Map.update!(acc, :reconnecting, &(&1 + 1))
        {_route_id, "restarting"}, acc -> Map.update!(acc, :restarting, &(&1 + 1))
        {_route_id, "failed"}, acc -> Map.update!(acc, :failed, &(&1 + 1))
        {_route_id, "stopped"}, acc -> Map.update!(acc, :stopped, &(&1 + 1))
        {_route_id, _status}, acc -> Map.update!(acc, :other, &(&1 + 1))
      end
    )
  end

  defp extract_new_status_from_details(details_json) when is_binary(details_json) do
    case Jason.decode(details_json) do
      {:ok, %{"new_status" => status}} when is_binary(status) -> status
      _ -> nil
    end
  end

  defp extract_new_status_from_details(_value), do: nil

  defp timestamp_to_ms(%DateTime{} = value), do: DateTime.to_unix(value, :millisecond)

  defp timestamp_to_ms(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:millisecond)
  end

  defp timestamp_to_ms(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp timestamp_to_ms(_value), do: nil

  defp align_ts_to_bucket(ts_ms, bucket_ms)
       when is_integer(ts_ms) and is_integer(bucket_ms) and bucket_ms > 0 do
    div(ts_ms, bucket_ms) * bucket_ms
  end

  defp ceil_ts_to_bucket(ts_ms, bucket_ms)
       when is_integer(ts_ms) and is_integer(bucket_ms) and bucket_ms > 0 do
    aligned = align_ts_to_bucket(ts_ms, bucket_ms)
    if aligned == ts_ms, do: aligned, else: aligned + bucket_ms
  end

  defp ms_to_iso8601(ts_ms) when is_integer(ts_ms) do
    ts_ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp normalize_route_status(status) when is_binary(status) do
    case String.downcase(status) do
      "started" -> "processing"
      "stopping" -> "stopped"
      value -> value
    end
  end

  defp normalize_route_status(_status), do: "other"

  defp fetch_route_events_total(route_id, range, type_filter, conn) do
    sql = """
    SELECT COUNT(*) AS total
    FROM events
    WHERE route_id = ?
      AND ts >= CAST(? AS TIMESTAMP)
      AND ts <= CAST(? AS TIMESTAMP)
      AND (? IS NULL OR event_type = ?)
    """

    params = [
      route_id,
      DateTime.to_iso8601(range.from),
      DateTime.to_iso8601(range.to),
      type_filter,
      type_filter
    ]

    case Adbc.Connection.query(conn, sql, params) do
      {:ok, result} ->
        result
        |> Adbc.Result.to_map()
        |> Map.get("total", [0])
        |> List.first(0)
        |> case do
          value when is_integer(value) -> value
          value when is_float(value) -> trunc(value)
          _ -> 0
        end

      {:error, _reason} ->
        0
    end
  end

  defp fetch_route_srt_quality(route_id, query_params, conn) do
    sql = """
    WITH sampled AS (
      SELECT
        to_timestamp(FLOOR(epoch_ms(ts)::DOUBLE / ?) * ? / 1000.0) AS bucket_ts,
        entity_id AS source_id,
        metric_key,
        avg(value_double) AS metric_value
      FROM stats_samples
      WHERE route_id = ?
        AND entity_type = 'source'
        AND metric_key IN ('srt_packet_loss', 'srt_rtt_ms')
        AND ts >= CAST(? AS TIMESTAMP)
        AND ts <= CAST(? AS TIMESTAMP)
      GROUP BY 1, 2, 3
    )
    SELECT bucket_ts, source_id, metric_key, metric_value
    FROM sampled
    ORDER BY bucket_ts ASC, source_id ASC, metric_key ASC
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
        quality_rows_from_columns(Adbc.Result.to_map(result))

      {:error, _reason} ->
        []
    end
  end

  defp quality_rows_from_columns(columns) when is_map(columns) do
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
          "timestamp" => normalize_timestamp(value_at(columns, "bucket_ts", index)),
          "source_id" => value_at(columns, "source_id", index),
          "metric_key" => value_at(columns, "metric_key", index),
          "value" => number_or_nil(value_at(columns, "metric_value", index))
        }
      end)
      |> Enum.reject(fn row ->
        is_nil(row["timestamp"]) or is_nil(row["source_id"]) or is_nil(row["metric_key"])
      end)
    end
  end

  defp node_rows_from_columns(columns) when is_map(columns) do
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
          metric_key: value_at(columns, "metric_key", index),
          metric_value: value_at(columns, "metric_value", index)
        }
      end)
      |> Enum.reject(&is_nil(&1.bucket_ts))
    end
  end

  defp node_points_from_rows(rows) when is_list(rows) do
    rows
    |> Enum.reduce(%{}, fn row, acc ->
      timestamp = normalize_timestamp(row.bucket_ts)

      current =
        Map.get(acc, timestamp, %{
          timestamp: timestamp,
          cpu: nil,
          ram: nil,
          swap: nil,
          la_avg1: nil,
          la_avg5: nil,
          la_avg15: nil
        })

      value = number_or_nil(row.metric_value)

      updated =
        cond do
          row.entity_type == "node" and row.metric_key == "cpu_util" ->
            Map.put(current, :cpu, value)

          row.entity_type == "node" and row.metric_key == "ram_usage" ->
            Map.put(current, :ram, value)

          row.entity_type == "node" and row.metric_key == "swap_usage" ->
            Map.put(current, :swap, value)

          row.entity_type == "node" and row.metric_key == "cpu_la_avg1" ->
            Map.put(current, :la_avg1, value)

          row.entity_type == "node" and row.metric_key == "cpu_la_avg5" ->
            Map.put(current, :la_avg5, value)

          row.entity_type == "node" and row.metric_key == "cpu_la_avg15" ->
            Map.put(current, :la_avg15, value)

          row.entity_type == "net_if" and row.metric_key == "net_rx_bytes_per_sec" ->
            case net_interface_name(row.entity_id) do
              nil -> current
              interface_name -> Map.put(current, :"net_in_#{interface_name}", value)
            end

          row.entity_type == "net_if" and row.metric_key == "net_tx_bytes_per_sec" ->
            case net_interface_name(row.entity_id) do
              nil -> current
              interface_name -> Map.put(current, :"net_out_#{interface_name}", value)
            end

          true ->
            current
        end

      Map.put(acc, timestamp, updated)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.timestamp)
  end

  defp net_interface_name(entity_id) when is_binary(entity_id) do
    case String.split(entity_id, ":", parts: 2) do
      [_node, interface_name] when interface_name != "" -> interface_name
      _ -> entity_id
    end
  end

  defp net_interface_name(_entity_id), do: nil
end

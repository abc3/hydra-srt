defmodule HydraSrt.Stats.VictoriaLogs do
  @moduledoc false

  require Logger

  alias HydraSrt.Stats.JsonLines
  alias HydraSrt.Stats.VictoriaHttp

  @default_timeout 5_000

  @spec insert_pipeline_logs([map()]) :: :ok | {:error, term()}
  def insert_pipeline_logs(rows) when is_list(rows) do
    rows
    |> Enum.map(&log_to_json_line/1)
    |> post_json_lines()
  end

  @spec query_route_logs(binary(), map()) :: {:ok, map()} | {:error, term()}
  def query_route_logs(route_id, params) when is_binary(route_id) and is_map(params) do
    limit = Map.get(params, :limit, 50)
    offset = Map.get(params, :offset, 0)
    levels = Map.get(params, :levels, [])
    categories = Map.get(params, :categories, [])

    query = route_query(route_id, levels, categories)

    form = %{
      "query" => "#{query} | sort by (_time desc) offset #{offset} limit #{limit}",
      "start" => DateTime.to_iso8601(Map.fetch!(params, :from)),
      "end" => DateTime.to_iso8601(Map.fetch!(params, :to))
    }

    with {:ok, body} <-
           VictoriaHttp.post_form(endpoint("/select/logsql/query"), form, request_opts()),
         {:ok, total} <- count_route_logs(query, params) do
      rows =
        body
        |> parse_json_lines()
        |> Enum.map(&json_log_to_row/1)

      {:ok, %{logs: rows, total: total}}
    end
  end

  @spec distinct_route_values(binary(), binary()) :: {:ok, [binary()]} | {:error, term()}
  def distinct_route_values(route_id, column)
      when is_binary(route_id) and column in ["level", "category"] do
    form = %{
      "query" => route_query(route_id),
      "field" => column,
      "limit" => 1_000
    }

    with {:ok, body} <-
           VictoriaHttp.post_form(endpoint("/select/logsql/field_values"), form, request_opts()) do
      {:ok, parse_field_values(body)}
    end
  end

  @spec empty_summary() :: map()
  def empty_summary do
    %{
      errors: 0,
      warnings: 0,
      info: 0,
      last_error_at: nil,
      last_error_route_id: nil,
      last_error_message: nil
    }
  end

  # Bounds the per-route last-error scan so one route cannot flood the window.
  # A route whose newest error falls outside the 200 most recent error/fatal
  # logs across the batch will not surface here (acceptable for a dashboard
  # "last error" glance; exact level counts come from server-side stats).
  @last_error_scan_limit 200

  @error_levels ~w(ERROR FATAL)

  @doc """
  Fetches a level/error summary for the given routes using a CONSTANT number of
  HTTP requests (two batched LogsQL queries filtered with `route_id:in(...)`),
  propagating backend outages as `{:error, reason}` so callers can tell an empty
  window apart from an unavailable backend.

  Level counts come from a server-side `stats by (route_id, level)` aggregation
  (exact, never truncated by a noisy route), and the last error is taken from a
  bounded, time-ordered error/fatal scan (see `@last_error_scan_limit`). This
  preserves per-route fairness that a single raw `limit 1000` window would lose.
  """
  @spec summary_result([binary()]) :: {:ok, map()} | {:error, term()}
  def summary_result([]), do: {:ok, empty_summary()}

  def summary_result(route_ids) when is_list(route_ids) do
    from = DateTime.utc_now() |> DateTime.add(-5 * 60, :second)
    to = DateTime.utc_now()

    with {:ok, stats_body} <- post_query(level_stats_query(route_ids), from, to),
         {:ok, error_body} <- post_query(last_error_query(route_ids), from, to) do
      stats_rows = parse_json_lines(stats_body)
      error_rows = error_body |> parse_json_lines() |> Enum.map(&json_log_to_row/1)

      {:ok, summary_from_level_stats(stats_rows, error_rows)}
    end
  end

  @spec post_query(binary(), DateTime.t(), DateTime.t()) :: {:ok, binary()} | {:error, term()}
  defp post_query(query, from, to) when is_binary(query) do
    form = %{
      "query" => query,
      "start" => DateTime.to_iso8601(from),
      "end" => DateTime.to_iso8601(to)
    }

    VictoriaHttp.post_form(endpoint("/select/logsql/query"), form, request_opts())
  end

  @doc """
  Server-side per-route level aggregation. Returns exact counts regardless of how
  many rows any single route produced, unlike a raw-row window.
  """
  @spec level_stats_query([binary()]) :: binary()
  def level_stats_query(route_ids) when is_list(route_ids) do
    "#{routes_query(route_ids)} | stats by (route_id, level) count() rows"
  end

  @doc """
  Bounded, time-ordered scan of error/fatal logs across the batch, used to derive
  the most recent error. Capped at `@last_error_scan_limit` rows.
  """
  @spec last_error_query([binary()]) :: binary()
  def last_error_query(route_ids) when is_list(route_ids) do
    [routes_query(route_ids), in_filter("level", @error_levels)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> Kernel.<>(" | sort by (_time desc) | limit #{@last_error_scan_limit}")
  end

  @spec summary([binary()]) :: map()
  def summary(route_ids) when is_list(route_ids) do
    case summary_result(route_ids) do
      {:ok, summary} -> summary
      {:error, _reason} -> empty_summary()
    end
  end

  @spec routes_query([binary()]) :: binary()
  def routes_query(route_ids) when is_list(route_ids) do
    case in_filter("route_id", route_ids) do
      "" -> "{app=\"hydra_srt\"}"
      filter -> "{app=\"hydra_srt\"} #{filter}"
    end
  end

  @doc """
  Builds the dashboard log summary from server-side per-route level stats and a
  bounded set of error/fatal rows. Counts are summed across every `(route_id,
  level)` stats bucket, and the last error is the most recent row in the scan.
  """
  @spec summary_from_level_stats([map()], [map()]) :: map()
  def summary_from_level_stats(stats_rows, error_rows)
      when is_list(stats_rows) and is_list(error_rows) do
    counts = level_counts_from_stats(stats_rows)
    latest_error = latest_error_from_rows(error_rows)

    %{
      errors: counts.errors,
      warnings: counts.warnings,
      info: counts.info,
      last_error_at: latest_error && latest_error["ts"],
      last_error_route_id: latest_error && latest_error["route_id"],
      last_error_message: latest_error && latest_error["message"]
    }
  end

  @spec level_counts_from_stats([map()]) :: %{
          errors: non_neg_integer(),
          warnings: non_neg_integer(),
          info: non_neg_integer()
        }
  def level_counts_from_stats(stats_rows) when is_list(stats_rows) do
    Enum.reduce(stats_rows, %{errors: 0, warnings: 0, info: 0}, fn row, acc ->
      count = parse_non_negative_int(Map.get(row, "rows"))

      case level_bucket(Map.get(row, "level")) do
        :error -> Map.update!(acc, :errors, &(&1 + count))
        :warning -> Map.update!(acc, :warnings, &(&1 + count))
        :info -> Map.update!(acc, :info, &(&1 + count))
        :other -> acc
      end
    end)
  end

  @spec latest_error_from_rows([map()]) :: map() | nil
  def latest_error_from_rows(rows) when is_list(rows) do
    rows
    |> Enum.filter(&(level_bucket(Map.get(&1, "level")) == :error))
    |> Enum.sort_by(&Map.get(&1, "ts", ""), :desc)
    |> List.first()
  end

  @spec level_bucket(term()) :: :error | :warning | :info | :other
  defp level_bucket(level) do
    case String.upcase(to_string(level)) do
      value when value in ["ERROR", "FATAL"] -> :error
      value when value in ["WARN", "WARNING"] -> :warning
      "INFO" -> :info
      _ -> :other
    end
  end

  @spec log_to_json_line(map()) :: binary()
  def log_to_json_line(row) when is_map(row) do
    row
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put("app", "hydra_srt")
    |> Map.put("_time", normalize_ts(Map.get(row, :ts) || Map.get(row, "ts")))
    |> Map.put("_msg", Map.get(row, :message) || Map.get(row, "message") || "")
    |> Jason.encode!()
  end

  @spec post_json_lines([binary()]) :: :ok | {:error, term()}
  def post_json_lines([]), do: :ok

  def post_json_lines(lines) when is_list(lines) do
    body = Enum.join(lines, "\n") <> "\n"
    path = "/insert/jsonline?_stream_fields=app,route_id,level,category"

    case VictoriaHttp.post(
           endpoint(path),
           body,
           [{"content-type", "application/stream+json"}],
           request_opts()
         ) do
      {:ok, _body} ->
        :ok

      {:error, reason} ->
        Logger.error("VictoriaLogs ingest failed reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec route_query(binary()) :: binary()
  def route_query(route_id) when is_binary(route_id) do
    "{app=\"hydra_srt\",route_id=#{inspect_stream_value(route_id)}}"
  end

  @spec route_query(binary(), [binary()], [binary()]) :: binary()
  def route_query(route_id, levels, categories)
      when is_binary(route_id) and is_list(levels) and is_list(categories) do
    [
      route_query(route_id),
      in_filter("level", levels),
      in_filter("category", categories)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  @spec count_route_logs(binary(), map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count_route_logs(query, params) when is_binary(query) and is_map(params) do
    form = %{
      "query" => "#{query} | stats count() as logs_total",
      "start" => DateTime.to_iso8601(Map.fetch!(params, :from)),
      "end" => DateTime.to_iso8601(Map.fetch!(params, :to))
    }

    with {:ok, body} <-
           VictoriaHttp.post_form(endpoint("/select/logsql/query"), form, request_opts()) do
      {:ok, parse_stats_count(body)}
    end
  end

  @spec in_filter(binary(), [binary()]) :: binary()
  def in_filter(_field, []), do: ""

  def in_filter(field, values) when is_binary(field) and is_list(values) do
    values =
      values
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))

    if values == [] do
      ""
    else
      "#{field}:in(#{Enum.map_join(values, ",", &inspect_stream_value/1)})"
    end
  end

  @spec inspect_stream_value(binary()) :: binary()
  def inspect_stream_value(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")
      |> strip_control_chars()

    "\"#{escaped}\""
  end

  # Removes any remaining raw control characters (other than the tab/newline/
  # carriage-return already escaped above) so interpolated values can never
  # break out of a quoted LogsQL string.
  @spec strip_control_chars(binary()) :: binary()
  defp strip_control_chars(value) when is_binary(value) do
    String.replace(value, ~r/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/, "")
  end

  @spec parse_json_lines(binary()) :: [map()]
  def parse_json_lines(body) when is_binary(body) do
    JsonLines.parse_json_lines(body)
  end

  @spec parse_field_values(binary()) :: [binary()]
  def parse_field_values(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, values} when is_list(values) ->
        values |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == "")) |> Enum.sort()

      _ ->
        parse_json_lines(body)
        |> Enum.flat_map(&Map.values/1)
        |> Enum.map(&to_string/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> Enum.sort()
    end
  end

  @spec parse_stats_count(binary()) :: non_neg_integer()
  def parse_stats_count(body) when is_binary(body) do
    body
    |> parse_json_lines()
    |> List.first(%{})
    |> Map.get("logs_total", 0)
    |> parse_non_negative_int()
  end

  @spec json_log_to_row(map()) :: map()
  def json_log_to_row(log) when is_map(log) do
    %{
      "ts" => Map.get(log, "_time") || Map.get(log, "ts"),
      "route_id" => Map.get(log, "route_id"),
      "gst_ts" => Map.get(log, "gst_ts"),
      "pid" => int_or_nil(Map.get(log, "pid")),
      "thread_id" => Map.get(log, "thread_id"),
      "level" => Map.get(log, "level"),
      "category" => Map.get(log, "category"),
      "element" => Map.get(log, "element"),
      "file" => Map.get(log, "file"),
      "line" => int_or_nil(Map.get(log, "line")),
      "function" => Map.get(log, "function"),
      "message" => Map.get(log, "_msg") || Map.get(log, "message"),
      "dropped_count" => int_or_nil(Map.get(log, "dropped_count")) || 0
    }
  end

  @spec filter_logs([map()], [binary()], [binary()]) :: [map()]
  def filter_logs(logs, levels, categories) when is_list(logs) do
    Enum.filter(logs, fn log ->
      level_match? = levels == [] or Map.get(log, "level") in levels
      category_match? = categories == [] or Map.get(log, "category") in categories
      level_match? and category_match?
    end)
  end

  @spec normalize_ts(term()) :: binary()
  def normalize_ts(%DateTime{} = value), do: DateTime.to_iso8601(value)

  def normalize_ts(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  def normalize_ts(value) when is_binary(value), do: value
  def normalize_ts(_value), do: DateTime.utc_now() |> DateTime.to_iso8601()

  @spec int_or_nil(term()) :: integer() | nil
  def int_or_nil(value) when is_integer(value), do: value

  def int_or_nil(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  def int_or_nil(_value), do: nil

  @spec parse_non_negative_int(term()) :: non_neg_integer()
  def parse_non_negative_int(value) when is_integer(value), do: max(value, 0)

  def parse_non_negative_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> max(parsed, 0)
      :error -> 0
    end
  end

  def parse_non_negative_int(_value), do: 0

  @spec endpoint(binary()) :: binary()
  def endpoint(path) when is_binary(path) do
    base =
      :hydra_srt
      |> Application.get_env(:victoria_logs_url, "http://127.0.0.1:9428")
      |> String.trim_trailing("/")

    base <> path
  end

  @spec request_opts() :: keyword()
  def request_opts do
    [timeout: Application.get_env(:hydra_srt, :victoria_logs_timeout_ms, @default_timeout)]
  end
end

defmodule HydraSrt.Stats.VictoriaMetrics do
  @moduledoc false

  require Logger

  alias HydraSrt.Stats.JsonLines
  alias HydraSrt.Stats.VictoriaHttp

  @stats_metric "hydra_srt_stats_sample"
  @event_metric "hydra_srt_route_event"
  @default_timeout 5_000
  # Route events are stored as VictoriaMetrics samples, so their free-text fields
  # (message, details_json) live as labels. This is a deliberate bound, not an
  # oversight: VictoriaMetrics rejects label values above its default
  # -maxLabelValueLen (16 KiB), which would fail the whole event write, so we cap
  # just below it. Real events (probe errors, source paths, status JSON) are far
  # smaller than 16 KB and are never affected. Overflow is handled gracefully
  # rather than corruptly: plain-text message is truncated (truncate_label/1),
  # and details_json is replaced with a valid {"_truncated":true} marker
  # (safe_details_label/1) so the read path never sees invalid JSON. Storing
  # unbounded event text would belong in VictoriaLogs, not VM labels; that is
  # intentionally out of scope here.
  @event_label_max_length 16_000

  @spec insert_rows([map()]) :: :ok | {:error, term()}
  def insert_rows(rows) when is_list(rows) do
    rows
    |> Enum.flat_map(&row_to_prometheus_lines/1)
    |> post_import()
  end

  @spec insert_events([map()]) :: :ok | {:error, term()}
  def insert_events(events) when is_list(events) do
    events
    |> Enum.flat_map(&event_to_prometheus_lines/1)
    |> post_import()
  end

  @spec query_range(binary(), DateTime.t(), DateTime.t(), pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def query_range(query, from, to, step_seconds)
      when is_binary(query) and is_integer(step_seconds) and step_seconds > 0 do
    params = %{
      "query" => query,
      "start" => unix_seconds(from),
      "end" => unix_seconds(to),
      "step" => step_seconds
    }

    with {:ok, body} <-
           VictoriaHttp.post_form(endpoint("/api/v1/query_range"), params, request_opts()),
         {:ok, decoded} <- Jason.decode(body),
         %{"status" => "success", "data" => %{"result" => result}} <- decoded do
      {:ok, result}
    else
      %{"status" => status} = response ->
        {:error, {:victoria_metrics_query_failed, status, response}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_victoria_metrics_response, other}}
    end
  end

  @spec export_series(binary(), DateTime.t(), DateTime.t()) :: {:ok, [map()]} | {:error, term()}
  def export_series(match_expr, from, to) when is_binary(match_expr) do
    params = %{
      "match[]" => match_expr,
      "start" => DateTime.to_iso8601(from),
      "end" => DateTime.to_iso8601(to)
    }

    with {:ok, body} <- VictoriaHttp.post_form(endpoint("/api/v1/export"), params, request_opts()) do
      {:ok, parse_json_lines(body)}
    end
  end

  @spec stats_metric() :: binary()
  def stats_metric, do: @stats_metric

  @spec event_metric() :: binary()
  def event_metric, do: @event_metric

  @spec selector(binary(), map()) :: binary()
  def selector(metric_name, labels) when is_binary(metric_name) and is_map(labels) do
    label_text =
      labels
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map_join(",", fn {key, value} ->
        "#{key}=#{inspect_label_value(value)}"
      end)

    if label_text == "" do
      metric_name
    else
      "#{metric_name}{#{label_text}}"
    end
  end

  @doc """
  Builds an event-metric selector matching any of `route_ids` with a single
  regex-alternation matcher: `route_id=~"^(id1|id2|...)$"`. Each id is
  regex-escaped so it is matched literally. Returns the bare metric name when
  `route_ids` is empty (matches every route).
  """
  @spec event_selector_for_route_ids([binary()]) :: binary()
  def event_selector_for_route_ids(route_ids) when is_list(route_ids) do
    case Enum.reject(route_ids, &(is_nil(&1) or &1 == "")) do
      [] ->
        @event_metric

      ids ->
        pattern = Enum.map_join(ids, "|", &Regex.escape/1)
        "#{@event_metric}{route_id=~#{inspect_label_value("^(#{pattern})$")}}"
    end
  end

  @spec row_to_prometheus_lines(map()) :: [binary()]
  def row_to_prometheus_lines(row) when is_map(row) do
    case row_value(row) do
      nil ->
        []

      value ->
        labels = %{
          route_id: Map.get(row, :route_id) || "",
          entity_type: Map.get(row, :entity_type) || "",
          entity_id: Map.get(row, :entity_id) || "",
          metric_key: Map.get(row, :metric_key) || "",
          value_type: Map.get(row, :value_type) || "double"
        }

        [prometheus_line(@stats_metric, labels, value, row_ts_ms(row))]
    end
  end

  @spec event_to_prometheus_lines(map()) :: [binary()]
  def event_to_prometheus_lines(event) when is_map(event) do
    details_json = Map.get(event, :details_json)
    details = decode_details(details_json)

    labels = %{
      route_id: Map.get(event, :route_id) || "",
      event_type: Map.get(event, :event_type) || "unknown",
      severity: Map.get(event, :severity) || "info",
      source_id: Map.get(event, :source_id) || "",
      from_source_id: Map.get(event, :from_source_id) || "",
      to_source_id: Map.get(event, :to_source_id) || "",
      reason: Map.get(event, :reason) || "",
      # old_status/new_status stay as separate labels because they are queried
      # and filtered on directly; details_json carries the full payload so no
      # event field is lost on round-trip.
      old_status: Map.get(details, "old_status", ""),
      new_status: Map.get(details, "new_status", ""),
      details_json: safe_details_label(details_json || ""),
      message: truncate_label(Map.get(event, :message) || "")
    }

    [prometheus_line(@event_metric, labels, 1, row_ts_ms(event))]
  end

  @spec post_import([binary()]) :: :ok | {:error, term()}
  def post_import([]), do: :ok

  def post_import(lines) when is_list(lines) do
    body = Enum.join(lines, "\n") <> "\n"

    case VictoriaHttp.post(
           endpoint("/api/v1/import/prometheus"),
           body,
           [{"content-type", "text/plain"}],
           request_opts()
         ) do
      {:ok, _body} ->
        :ok

      {:error, reason} ->
        Logger.error("VictoriaMetrics import failed reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec prometheus_line(binary(), map(), number(), integer()) :: binary()
  def prometheus_line(metric_name, labels, value, ts_ms)
      when is_binary(metric_name) and is_map(labels) and is_number(value) and is_integer(ts_ms) do
    "#{selector(metric_name, labels)} #{value} #{ts_ms}"
  end

  @spec row_value(map()) :: number() | nil
  def row_value(row) when is_map(row) do
    cond do
      is_number(Map.get(row, :value_double)) -> Map.get(row, :value_double)
      is_number(Map.get(row, :value_bigint)) -> Map.get(row, :value_bigint)
      true -> nil
    end
  end

  @spec row_ts_ms(map()) :: integer()
  def row_ts_ms(row) when is_map(row) do
    case Map.get(row, :ts) do
      %DateTime{} = ts ->
        DateTime.to_unix(ts, :millisecond)

      %NaiveDateTime{} = ts ->
        ts |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)

      value when is_binary(value) ->
        parse_ts_ms(value)

      _ ->
        DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    end
  end

  @spec parse_ts_ms(binary()) :: integer()
  def parse_ts_ms(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt, :millisecond)
      _ -> DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    end
  end

  @spec inspect_label_value(term()) :: binary()
  def inspect_label_value(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\n", "\\n")
    |> String.replace("\"", "\\\"")
    |> then(&"\"#{&1}\"")
  end

  # Truncating JSON mid-string yields invalid JSON on read; emit a valid marker instead.
  @spec safe_details_label(binary()) :: binary()
  def safe_details_label(details_json) when is_binary(details_json) do
    if byte_size(details_json) <= @event_label_max_length do
      details_json
    else
      Jason.encode!(%{"_truncated" => true, "bytes" => byte_size(details_json)})
    end
  end

  # VictoriaMetrics -maxLabelValueLen is a byte bound; truncate on a valid UTF-8 boundary.
  @spec truncate_label(binary()) :: binary()
  def truncate_label(value) when is_binary(value) do
    if byte_size(value) <= @event_label_max_length do
      value
    else
      truncate_to_valid_utf8(value, @event_label_max_length)
    end
  end

  def truncate_label(value), do: value |> to_string() |> truncate_label()

  defp truncate_to_valid_utf8(value, max_bytes) do
    <<candidate::binary-size(max_bytes), _rest::binary>> = value
    trim_to_valid_utf8(candidate)
  end

  defp trim_to_valid_utf8(<<>>), do: <<>>

  defp trim_to_valid_utf8(bin) do
    if String.valid?(bin),
      do: bin,
      else: trim_to_valid_utf8(binary_part(bin, 0, byte_size(bin) - 1))
  end

  @spec parse_json_lines(binary()) :: [map()]
  def parse_json_lines(body) when is_binary(body) do
    JsonLines.parse_json_lines(body)
  end

  @spec endpoint(binary()) :: binary()
  def endpoint(path) when is_binary(path) do
    base =
      :hydra_srt
      |> Application.get_env(:victoria_metrics_url, "http://127.0.0.1:8428")
      |> String.trim_trailing("/")

    base <> path
  end

  @spec request_opts() :: keyword()
  def request_opts do
    [timeout: Application.get_env(:hydra_srt, :victoria_metrics_timeout_ms, @default_timeout)]
  end

  @spec unix_seconds(DateTime.t()) :: integer()
  def unix_seconds(%DateTime{} = value), do: DateTime.to_unix(value, :second)

  @spec decode_details(term()) :: map()
  def decode_details(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  def decode_details(_value), do: %{}
end

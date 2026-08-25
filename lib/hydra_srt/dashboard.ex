defmodule HydraSrt.Dashboard do
  @moduledoc false

  alias HydraSrt.Db
  alias HydraSrt.Monitoring.NodeStats
  alias HydraSrt.Stats.Analytics
  alias HydraSrt.Stats.VictoriaLogs

  @healthy_statuses ~w(processing started stopped)
  @attention_statuses ~w(starting reconnecting restarting failed)
  @status_series_keys ~w(processing starting reconnecting restarting failed stopped other)a

  @spec snapshot() :: {:ok, map()} | {:error, term()}
  def snapshot do
    with {:ok, routes} <- Db.get_all_routes(true) do
      node = NodeStats.self_node_stats()
      node_id = node.host |> to_string()
      query_params = dashboard_query_params()
      status_history = status_history(query_params)
      node_history = node_history(node_id, query_params)
      route_ids = Enum.map(routes, & &1["id"])
      event_summary = event_summary(route_ids)
      log_summary = log_summary(route_ids)

      generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      analytics_available =
        status_history.available and node_history.available and
          event_summary.available and log_summary.available

      {:ok,
       %{
         generated_at: generated_at,
         system: system_summary(node),
         routes: route_summary(routes),
         failover: failover_summary(routes, event_summary),
         logs: log_summary.summary,
         network_series: network_series(node_history.points),
         status_series: reconcile_status_series(status_history.points, routes, generated_at),
         attention: attention_rows(routes, event_summary.latest_by_route),
         analytics_available: analytics_available
       }}
    end
  end

  @spec dashboard_query_params() :: map()
  def dashboard_query_params do
    {:ok, query_params} = Analytics.build_query_params(%{"window" => "last_hour"})
    query_params
  end

  @spec status_history(map()) :: %{available: boolean(), points: list()}
  def status_history(query_params) when is_map(query_params) do
    case Analytics.fetch_routes_status_timeseries(query_params) do
      {:ok, %{points: points}} -> %{available: true, points: points}
      {:error, _reason} -> %{available: false, points: []}
    end
  end

  @spec node_history(binary(), map()) :: %{available: boolean(), points: list()}
  def node_history(node_id, query_params) when is_binary(node_id) and is_map(query_params) do
    case Analytics.fetch_node_timeseries(node_id, query_params) do
      {:ok, %{points: points}} -> %{available: true, points: points}
      {:error, _reason} -> %{available: false, points: []}
    end
  end

  @spec system_summary(map()) :: map()
  def system_summary(node) when is_map(node) do
    storage = primary_storage(Map.get(node, :storage, %{}))

    %{
      host: node.host,
      cpu_percent: number_or_nil(node.cpu),
      cpu_count: logical_processor_count(),
      memory_percent: number_or_nil(node.ram),
      memory_total_bytes: memory_total_bytes(),
      swap_percent: number_or_nil(node.swap),
      storage: storage,
      network_in_bytes_per_sec: number_or_nil(node.network_in_bytes_per_sec),
      network_out_bytes_per_sec: number_or_nil(node.network_out_bytes_per_sec)
    }
  end

  @spec logical_processor_count() :: non_neg_integer() | nil
  def logical_processor_count do
    case :erlang.system_info(:logical_processors_available) do
      value when is_integer(value) and value > 0 -> value
      _ -> nil
    end
  end

  @spec memory_total_bytes() :: non_neg_integer() | nil
  def memory_total_bytes do
    case Keyword.get(:memsup.get_system_memory_data(), :total_memory) do
      value when is_integer(value) and value > 0 -> value
      _ -> nil
    end
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  @spec primary_storage(map()) :: map() | nil
  def primary_storage(storage) when is_map(storage) do
    entries = Map.values(storage)

    Enum.find(entries, &(map_value(&1, :mountpoint) == "/")) ||
      Enum.max_by(entries, &(map_value(&1, :total_bytes) || 0), fn -> nil end)
  end

  def primary_storage(_storage), do: nil

  @spec route_summary([map()]) :: map()
  def route_summary(routes) when is_list(routes) do
    %{
      total: length(routes),
      statuses: count_by(routes, &route_status/1),
      source_protocols: protocol_counts(routes, "sources"),
      destination_protocols: protocol_counts(routes, "destinations")
    }
  end

  @spec route_status_counts([map()]) :: map()
  def route_status_counts(routes) when is_list(routes) do
    base = Map.new(@status_series_keys, fn key -> {key, 0} end)

    Enum.reduce(routes, base, fn route, acc ->
      key =
        case route_status(route) do
          "processing" -> :processing
          "starting" -> :starting
          "reconnecting" -> :reconnecting
          "restarting" -> :restarting
          "failed" -> :failed
          "stopped" -> :stopped
          _other -> :other
        end

      Map.update!(acc, key, &(&1 + 1))
    end)
  end

  @spec reconcile_status_series([map()], [map()], binary()) :: [map()]
  def reconcile_status_series(points, routes, timestamp)
      when is_list(points) and is_list(routes) and is_binary(timestamp) do
    current_point =
      routes
      |> route_status_counts()
      |> Map.put(:timestamp, timestamp)

    case points do
      [] -> [current_point]
      _points -> List.replace_at(points, -1, current_point)
    end
  end

  @spec count_by([term()], (term() -> binary())) :: map()
  def count_by(items, key_fun) when is_list(items) and is_function(key_fun, 1) do
    Enum.reduce(items, %{}, fn item, acc ->
      Map.update(acc, key_fun.(item), 1, &(&1 + 1))
    end)
  end

  @spec protocol_counts([map()], binary()) :: map()
  def protocol_counts(routes, endpoint_key) when is_list(routes) and is_binary(endpoint_key) do
    routes
    |> Enum.flat_map(&Map.get(&1, endpoint_key, []))
    |> Enum.reduce(%{}, fn endpoint, acc ->
      protocol = endpoint |> Map.get("schema", "unknown") |> to_string() |> String.upcase()
      Map.update(acc, protocol, 1, &(&1 + 1))
    end)
  end

  @spec failover_summary([map()], map()) :: map()
  def failover_summary(routes, event_summary) when is_list(routes) and is_map(event_summary) do
    %{
      on_backup: Enum.count(routes, &on_backup?/1),
      backup_unavailable: Enum.count(routes, &backup_unavailable?/1),
      last_failover_at: event_summary.last_failover_at,
      failbacks_today: event_summary.failbacks_today
    }
  end

  @spec on_backup?(map()) :: boolean()
  def on_backup?(route) when is_map(route) do
    active_source_id = route["active_source_id"]
    live_route = route_status(route) in ~w(processing starting reconnecting restarting)

    live_route and
      Enum.any?(route["sources"] || [], fn source ->
        source["id"] == active_source_id and (source["position"] || 0) > 0
      end)
  end

  @spec backup_unavailable?(map()) :: boolean()
  def backup_unavailable?(route) when is_map(route) do
    backups = Enum.filter(route["sources"] || [], &((&1["position"] || 0) > 0))

    route["enabled"] == true and backups != [] and
      Enum.all?(backups, fn source ->
        source["enabled"] == false or
          String.downcase(to_string(source["status"] || "")) == "failed"
      end)
  end

  @spec network_series([map()]) :: [map()]
  def network_series(points) when is_list(points) do
    Enum.map(points, fn point ->
      {input, output} =
        Enum.reduce(point, {0.0, 0.0}, fn
          {key, value}, {input, output} when is_binary(key) and is_number(value) ->
            cond do
              String.starts_with?(key, "net_in_") -> {input + value, output}
              String.starts_with?(key, "net_out_") -> {input, output + value}
              true -> {input, output}
            end

          _, totals ->
            totals
        end)

      %{timestamp: point[:timestamp] || point["timestamp"], input: input, output: output}
    end)
  end

  @spec log_summary([binary()]) :: %{available: boolean(), summary: map()}
  def log_summary(route_ids)

  def log_summary([]), do: %{available: true, summary: empty_log_summary()}

  def log_summary(route_ids) when is_list(route_ids) do
    case VictoriaLogs.summary_result(route_ids) do
      {:ok, summary} -> %{available: true, summary: summary}
      {:error, _reason} -> %{available: false, summary: empty_log_summary()}
    end
  rescue
    _error -> %{available: false, summary: empty_log_summary()}
  catch
    _kind, _reason -> %{available: false, summary: empty_log_summary()}
  end

  @spec empty_log_summary() :: map()
  def empty_log_summary do
    %{
      errors: 0,
      warnings: 0,
      info: 0,
      last_error_at: nil,
      last_error_route_id: nil,
      last_error_message: nil
    }
  end

  @spec event_summary([binary()]) :: map()
  def event_summary(route_ids)

  def event_summary([]), do: empty_event_summary(true)

  def event_summary(route_ids) when is_list(route_ids) do
    now = DateTime.utc_now()
    from_24h = DateTime.add(now, -24 * 60 * 60, :second)
    today = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")

    # One or more export calls scoped to route batches (regex matcher), then a
    # defensive in-memory filter.
    case fetch_event_summary_events(route_ids, from_24h, now) do
      {:ok, all_events} ->
        route_id_set = MapSet.new(route_ids)

        events =
          all_events
          |> Enum.filter(&MapSet.member?(route_id_set, &1["route_id"]))
          |> Enum.sort_by(& &1["ts"], :desc)

        latest_switch =
          Enum.find(events, fn event ->
            event["event_type"] == "source_switch" and event["reason"] != "manual"
          end)

        failbacks_today =
          Enum.count(events, fn event ->
            event["event_type"] == "source_switch" and event["reason"] == "primary_recovered" and
              timestamp_on_or_after?(event["ts"], today)
          end)

        %{
          last_failover_at: latest_switch && latest_switch["ts"],
          failbacks_today: failbacks_today,
          latest_by_route: latest_events_by_route_rows(events),
          available: true
        }

      {:error, _reason} ->
        empty_event_summary(false)
    end
  rescue
    _error -> empty_event_summary(false)
  catch
    _kind, _reason -> empty_event_summary(false)
  end

  # Above this many routes the regex-alternation selector grows too long, so we
  # chunk route ids and issue one constrained export per batch.
  @max_route_ids_for_regex 50

  @spec fetch_event_summary_events([binary()], DateTime.t(), DateTime.t()) ::
          {:ok, [map()]} | {:error, term()}
  defp fetch_event_summary_events(route_ids, from, to) when is_list(route_ids) do
    route_ids
    |> Enum.chunk_every(@max_route_ids_for_regex)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      case Analytics.fetch_events_for_route_ids(batch, from, to) do
        {:ok, events} -> {:cont, {:ok, acc ++ events}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec empty_event_summary(boolean()) :: map()
  def empty_event_summary(available) when is_boolean(available) do
    %{last_failover_at: nil, failbacks_today: 0, latest_by_route: %{}, available: available}
  end

  @spec latest_events_by_route_rows([map()]) :: map()
  def latest_events_by_route_rows(events) when is_list(events) do
    Enum.reduce(events, %{}, fn event, acc ->
      route_id = event["route_id"]

      if is_binary(route_id) and not Map.has_key?(acc, route_id) do
        Map.put(acc, route_id, %{
          ts: event["ts"],
          event_type: event["event_type"],
          severity: event["severity"],
          reason: event["reason"],
          message: event["message"]
        })
      else
        acc
      end
    end)
  end

  @spec timestamp_on_or_after?(binary() | nil, DateTime.t()) :: boolean()
  def timestamp_on_or_after?(nil, _datetime), do: false

  def timestamp_on_or_after?(timestamp, datetime) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> DateTime.compare(parsed, datetime) in [:eq, :gt]
      _ -> false
    end
  end

  @spec latest_events_by_route(map()) :: map()
  def latest_events_by_route(columns) when is_map(columns) do
    columns
    |> Map.get("route_id", [])
    |> Enum.with_index()
    |> Map.new(fn {route_id, index} ->
      {route_id,
       %{
         ts: columns |> value_at("ts", index) |> timestamp_to_iso8601(),
         event_type: value_at(columns, "event_type", index),
         severity: value_at(columns, "severity", index),
         reason: value_at(columns, "reason", index),
         message: value_at(columns, "message", index)
       }}
    end)
  end

  @spec attention_rows([map()], map()) :: [map()]
  def attention_rows(routes, latest_by_route) when is_list(routes) and is_map(latest_by_route) do
    routes
    |> Enum.map(&attention_row(&1, Map.get(latest_by_route, &1["id"])))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&attention_sort_key/1)
    |> Enum.take(10)
  end

  @spec attention_row(map(), map() | nil) :: map() | nil
  def attention_row(route, latest_event) when is_map(route) do
    status = route_status(route)
    on_backup = on_backup?(route)
    backup_unavailable = backup_unavailable?(route)
    enabled_but_stopped = route["enabled"] == true and status == "stopped"

    recent_problem =
      route["enabled"] == true and is_map(latest_event) and
        latest_event.severity in ["warning", "error"]

    if status in @attention_statuses or on_backup or backup_unavailable or enabled_but_stopped or
         recent_problem do
      %{
        id: route["id"],
        name: route["name"] || route["alias"] || route["id"],
        status: status,
        source_protocols: endpoint_protocols(route["sources"] || []),
        destination_protocols: endpoint_protocols(route["destinations"] || []),
        signal: attention_signal(status, on_backup, backup_unavailable, enabled_but_stopped),
        last_event: latest_event
      }
    end
  end

  @spec attention_sort_key(map()) :: tuple()
  def attention_sort_key(row) when is_map(row) do
    priority =
      case row.status do
        "failed" -> 0
        "reconnecting" -> 1
        "restarting" -> 2
        "starting" -> 3
        _ -> 4
      end

    {priority, row.name}
  end

  @spec attention_signal(binary(), boolean(), boolean(), boolean()) :: binary()
  def attention_signal(_status, _on_backup, true, _enabled_but_stopped), do: "Backup unavailable"

  def attention_signal(_status, true, _backup_unavailable, _enabled_but_stopped),
    do: "Backup active"

  def attention_signal("failed", _on_backup, _backup_unavailable, _enabled_but_stopped),
    do: "Pipeline failed"

  def attention_signal("reconnecting", _on_backup, _backup_unavailable, _enabled_but_stopped),
    do: "Reconnecting"

  def attention_signal("restarting", _on_backup, _backup_unavailable, _enabled_but_stopped),
    do: "Restarting"

  def attention_signal("starting", _on_backup, _backup_unavailable, _enabled_but_stopped),
    do: "Starting"

  def attention_signal(_status, _on_backup, _backup_unavailable, true), do: "Enabled but stopped"

  def attention_signal(_status, _on_backup, _backup_unavailable, _enabled_but_stopped),
    do: "Recent warning"

  @spec route_status(map()) :: binary()
  def route_status(route) when is_map(route) do
    route
    |> then(&(&1["schema_status"] || &1["status"] || "other"))
    |> to_string()
    |> String.downcase()
    |> case do
      "started" -> "processing"
      "stopping" -> "stopped"
      value when value in @healthy_statuses or value in @attention_statuses -> value
      _value -> "other"
    end
  end

  @spec endpoint_protocols([map()]) :: [binary()]
  def endpoint_protocols(endpoints) when is_list(endpoints) do
    endpoints
    |> Enum.map(&(&1["schema"] || "unknown"))
    |> Enum.map(&(to_string(&1) |> String.upcase()))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec placeholders(list()) :: binary()
  def placeholders(values) when is_list(values) do
    Enum.map_join(values, ", ", fn _value -> "?" end)
  end

  @spec first_integer(map(), binary()) :: non_neg_integer()
  def first_integer(columns, key) when is_map(columns) and is_binary(key) do
    case first_value(columns, key) do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      _ -> 0
    end
  end

  @spec first_value(map(), binary()) :: term()
  def first_value(columns, key) when is_map(columns) and is_binary(key) do
    columns |> Map.get(key, []) |> List.first()
  end

  @spec value_at(map(), binary(), non_neg_integer()) :: term()
  def value_at(columns, key, index) do
    columns |> Map.get(key, []) |> Enum.at(index)
  end

  @spec timestamp_to_iso8601(term()) :: binary() | nil
  def timestamp_to_iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)

  def timestamp_to_iso8601(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  def timestamp_to_iso8601(value) when is_binary(value), do: value
  def timestamp_to_iso8601(_value), do: nil

  @spec number_or_nil(term()) :: number() | nil
  def number_or_nil(value) when is_number(value), do: value
  def number_or_nil(_value), do: nil

  @spec map_value(map(), atom()) :: term()
  def map_value(map, key) when is_map(map) and is_atom(key), do: map[key] || map[to_string(key)]
end

defmodule HydraSrt.Stats.SystemTelemetryCollector do
  @moduledoc false
  use GenServer
  require Logger

  alias HydraSrt.Monitoring.NetIfMetrics
  alias HydraSrt.Monitoring.OsMonTelemetry
  alias HydraSrt.Stats.Duckdb

  @event_cpu_util OsMonTelemetry.cpu_util_event()
  @event_ram_usage OsMonTelemetry.ram_usage_event()
  @event_swap_usage OsMonTelemetry.swap_usage_event()
  @event_cpu_la OsMonTelemetry.cpu_la_event()
  @event_memory OsMonTelemetry.memory_event()
  @event_network_interface OsMonTelemetry.network_interface_event()
  @event_storage OsMonTelemetry.storage_event()
  @event_database OsMonTelemetry.database_event()

  @default_flush_interval_ms 5_000
  @default_max_batch_size 1_000
  @default_max_buffer_size 10_000

  @memory_metric_keys %{
    available: "memory_available_bytes",
    buffered: "memory_buffered_bytes",
    cached: "memory_cached_bytes",
    free: "memory_free_bytes",
    total: "memory_total_bytes",
    system_total: "memory_system_total_bytes"
  }

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    enabled = Keyword.get(opts, :enabled, true)

    if enabled do
      flush_interval_ms = Keyword.get(opts, :flush_interval_ms, @default_flush_interval_ms)
      max_batch_size = Keyword.get(opts, :max_batch_size, @default_max_batch_size)
      max_buffer_size = Keyword.get(opts, :max_buffer_size, @default_max_buffer_size)
      handler_prefix = Keyword.get(opts, :handler_prefix, "stats-osmon")

      handler_ids = attach_handlers(handler_prefix, self())
      schedule_flush(flush_interval_ms)

      {:ok,
       %{
         enabled: true,
         rows: [],
         row_count: 0,
         flush_interval_ms: flush_interval_ms,
         max_batch_size: max_batch_size,
         max_buffer_size: max_buffer_size,
         handler_ids: handler_ids
       }}
    else
      {:ok,
       %{
         enabled: false,
         rows: [],
         row_count: 0,
         flush_interval_ms: @default_flush_interval_ms,
         handler_ids: []
       }}
    end
  end

  @impl true
  def handle_info({:telemetry_osmon, event_name, measurements, metadata}, state) do
    now = DateTime.utc_now()
    merged_measurements = Map.merge(measurements, normalize_metadata(metadata))

    rows =
      rows_from_telemetry(event_name, merged_measurements)
      |> Enum.map(&put_default_row_fields(&1, now))

    next_rows = rows ++ state.rows
    next_row_count = state.row_count + length(rows)
    {next_rows, next_row_count} = enforce_max_buffer(next_rows, next_row_count, state)

    if next_row_count >= state.max_batch_size do
      {rows_after_flush, row_count_after_flush, result} = flush_rows(next_rows, next_row_count)
      log_flush_error(result)
      {:noreply, %{state | rows: rows_after_flush, row_count: row_count_after_flush}}
    else
      {:noreply, %{state | rows: next_rows, row_count: next_row_count}}
    end
  end

  def handle_info(:flush, %{enabled: true} = state) do
    {rows_after_flush, row_count_after_flush, result} = flush_rows(state.rows, state.row_count)
    log_flush_error(result)
    schedule_flush(state.flush_interval_ms)
    {:noreply, %{state | rows: rows_after_flush, row_count: row_count_after_flush}}
  end

  def handle_info(:flush, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{
        enabled: true,
        rows: rows,
        row_count: row_count,
        handler_ids: handler_ids
      }) do
    {_rows, _row_count, result} = flush_rows(rows, row_count)
    log_flush_error(result)
    detach_handlers(handler_ids)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  def telemetry_handler(event_name, measurements, metadata, config) do
    target = config[:target]

    if is_pid(target) and Process.alive?(target) do
      send(target, {:telemetry_osmon, event_name, measurements, metadata})
    end
  end

  defp attach_handlers(prefix, target_pid) when is_binary(prefix) and is_pid(target_pid) do
    [
      {"#{prefix}-memory", OsMonTelemetry.memory_event()},
      {"#{prefix}-ram", OsMonTelemetry.ram_usage_event()},
      {"#{prefix}-cpu", OsMonTelemetry.cpu_util_event()},
      {"#{prefix}-la", OsMonTelemetry.cpu_la_event()},
      {"#{prefix}-swap", OsMonTelemetry.swap_usage_event()},
      {"#{prefix}-netif", OsMonTelemetry.network_interface_event()},
      {"#{prefix}-storage", OsMonTelemetry.storage_event()},
      {"#{prefix}-database", OsMonTelemetry.database_event()}
    ]
    |> Enum.map(fn {handler_id, event_name} ->
      maybe_attach(handler_id, event_name, target_pid)
      handler_id
    end)
  end

  defp maybe_attach(handler_id, event_name, target_pid) do
    :telemetry.detach(handler_id)
    :telemetry.attach(handler_id, event_name, &__MODULE__.telemetry_handler/4, target: target_pid)
  rescue
    error ->
      Logger.error(
        "System telemetry attach failed #{inspect(handler_id)} reason=#{inspect(error)}"
      )
  end

  defp detach_handlers(handler_ids) when is_list(handler_ids) do
    Enum.each(handler_ids, &:telemetry.detach/1)
  end

  defp put_default_row_fields(row, now) do
    Map.merge(
      %{
        ts: now,
        route_id: nil,
        entity_type: "node",
        entity_id: Atom.to_string(node()),
        value_type: "double",
        value_double: nil,
        value_bigint: nil,
        value_text: nil
      },
      row
    )
  end

  @doc false
  def rows_from_telemetry(event_name, measurements)

  def rows_from_telemetry(_event_name, measurements) when not is_map(measurements) do
    []
  end

  def rows_from_telemetry(event_name, measurements) do
    cond do
      event_name == @event_cpu_util ->
        number_row("cpu_util", Map.get(measurements, :cpu))

      event_name == @event_ram_usage ->
        number_row("ram_usage", Map.get(measurements, :ram))

      event_name == @event_swap_usage ->
        number_row("swap_usage", Map.get(measurements, :swap))

      event_name == @event_cpu_la ->
        number_row("cpu_la_avg1", Map.get(measurements, :avg1)) ++
          number_row("cpu_la_avg5", Map.get(measurements, :avg5)) ++
          number_row("cpu_la_avg15", Map.get(measurements, :avg15))

      event_name == @event_memory ->
        Enum.flat_map(@memory_metric_keys, fn {measurement_key, metric_key} ->
          number_row(metric_key, Map.get(measurements, measurement_key))
        end)

      event_name == @event_network_interface ->
        interface = Map.get(measurements, :interface)
        network_rows(measurements, interface)

      event_name == @event_storage ->
        mountpoint = Map.get(measurements, :mountpoint)
        storage_rows(measurements, mountpoint)

      event_name == @event_database ->
        database = Map.get(measurements, :id) || Map.get(measurements, :database)
        database_rows(measurements, database)

      true ->
        []
    end
  end

  defp number_row(_metric_key, value) when not is_number(value), do: []

  defp number_row(metric_key, value) when is_binary(metric_key) and is_number(value) do
    [
      %{
        metric_key: metric_key,
        value_double: value * 1.0
      }
    ]
  end

  defp network_rows(measurements, interface) when is_map(measurements) and is_binary(interface) do
    node_interface_id = "#{Atom.to_string(node())}:#{interface}"

    [
      metric_rows(measurements, NetIfMetrics.total_metric_keys()),
      metric_rows(measurements, net_rate_measurement_keys())
    ]
    |> List.flatten()
    |> Enum.map(&Map.put(&1, :entity_type, "net_if"))
    |> Enum.map(&Map.put(&1, :entity_id, node_interface_id))
  end

  defp network_rows(_measurements, _interface), do: []

  def storage_rows(measurements, mountpoint)
      when is_map(measurements) and is_binary(mountpoint) do
    node_storage_id = "#{Atom.to_string(node())}:#{mountpoint}"

    metric_rows(measurements, %{
      total_bytes: "storage_total_bytes",
      used_bytes: "storage_used_bytes",
      free_bytes: "storage_free_bytes",
      used_percent: "storage_used_percent"
    })
    |> Enum.map(&Map.put(&1, :entity_type, "storage"))
    |> Enum.map(&Map.put(&1, :entity_id, node_storage_id))
  end

  def storage_rows(_measurements, _mountpoint), do: []

  def database_rows(measurements, database)
      when is_map(measurements) and is_binary(database) do
    node_database_id = "#{Atom.to_string(node())}:#{database}"

    metric_rows(measurements, %{
      size_bytes: "database_size_bytes"
    })
    |> Enum.map(&Map.put(&1, :entity_type, "database"))
    |> Enum.map(&Map.put(&1, :entity_id, node_database_id))
  end

  def database_rows(_measurements, _database), do: []

  defp metric_rows(measurements, metric_map) when is_map(measurements) and is_map(metric_map) do
    Enum.flat_map(metric_map, fn {measurement_key, metric_key} ->
      number_row(metric_key, Map.get(measurements, measurement_key))
    end)
  end

  defp net_rate_measurement_keys do
    NetIfMetrics.rate_metric_keys()
    |> Enum.into(%{}, fn {counter_key, metric_key} ->
      {NetIfMetrics.rate_counter_key(counter_key), metric_key}
    end)
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp flush_rows([], 0), do: {[], 0, :ok}

  defp flush_rows(rows, row_count)
       when is_list(rows) and is_integer(row_count) and row_count >= 0 do
    to_insert = Enum.reverse(rows)

    case Duckdb.insert_rows(to_insert) do
      :ok -> {[], 0, :ok}
      {:error, reason} -> {rows, row_count, {:error, reason}}
    end
  end

  defp enforce_max_buffer(rows, row_count, %{max_buffer_size: max_buffer_size})
       when is_integer(max_buffer_size) and max_buffer_size > 0 and row_count > max_buffer_size do
    dropped = row_count - max_buffer_size

    Logger.warning(
      "System telemetry collector dropped #{dropped} buffered rows due to max_buffer_size"
    )

    {Enum.take(rows, max_buffer_size), max_buffer_size}
  end

  defp enforce_max_buffer(rows, row_count, _state), do: {rows, row_count}

  defp schedule_flush(flush_interval_ms)
       when is_integer(flush_interval_ms) and flush_interval_ms > 0 do
    Process.send_after(self(), :flush, flush_interval_ms)
  end

  defp log_flush_error(:ok), do: :ok

  defp log_flush_error({:error, reason}) do
    Logger.error("System telemetry collector flush failed reason=#{inspect(reason)}")
    :ok
  end
end

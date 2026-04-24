defmodule HydraSrt.StatsProcessor do
  @moduledoc false

  require Logger

  alias HydraSrt.Metrics
  alias HydraSrt.StatsHistory

  @persist_error_log_interval_ms 10_000
  @persist_error_log_key {__MODULE__, :last_persist_error_log_ms}

  def process_stats_json(json, %{route_id: route_id} = data) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, stats} ->
        try do
          stats = enrich_runtime_status(stats, data)
          HydraSrt.StatsStore.put(route_id, stats)

          Phoenix.PubSub.broadcast(
            HydraSrt.PubSub,
            "stats:#{route_id}",
            {:stats, stats}
          )

          schedule_persist_stats_snapshot(route_id, data, stats)

          export? =
            !!(get_in(data, [:route_record, "exportStats"]) &&
                 Application.get_env(:hydra_srt, :export_metrics?))

          stats_to_metrics(stats, data, export?)
        rescue
          error ->
            Logger.error(
              "Error processing stats: #{inspect(error)} route_id=#{inspect(route_id)} source_stream_id=#{inspect(data.source_stream_id)}"
            )
        end

      {:error, reason} ->
        Logger.error("Error decoding stats: #{inspect(reason)} #{inspect(json)}")
    end

    :ok
  end

  def process_pipeline_status(%{route_id: route_id} = data) when is_binary(route_id) do
    try do
      latest_stats =
        case HydraSrt.StatsStore.get(route_id) do
          {:ok, %{stats: stats}} when is_map(stats) -> stats
          _ -> baseline_stats_snapshot(data)
        end

      stats =
        latest_stats
        |> ensure_stats_shape(data)
        |> enrich_runtime_status(data)

      HydraSrt.StatsStore.put(route_id, stats)

      Phoenix.PubSub.broadcast(
        HydraSrt.PubSub,
        "stats:#{route_id}",
        {:stats, stats}
      )

      schedule_persist_stats_snapshot(route_id, data, stats)
    rescue
      error ->
        Logger.error(
          "Error processing pipeline status stats route_id=#{inspect(route_id)}: #{inspect(error)}"
        )
    end

    :ok
  end

  def process_pipeline_status(_data), do: :ok

  def schedule_persist_stats_snapshot(route_id, data, stats) when is_map(stats) do
    if Application.get_env(:hydra_srt, :stats_persist_async?, true) do
      case Process.whereis(HydraSrt.TaskSupervisor) do
        nil ->
          persist_stats_snapshot(route_id, data, stats)

        _pid ->
          Task.Supervisor.start_child(HydraSrt.TaskSupervisor, fn ->
            persist_stats_snapshot(route_id, data, stats)
          end)

          :ok
      end
    else
      persist_stats_snapshot(route_id, data, stats)
    end
  end

  def schedule_persist_stats_snapshot(_route_id, _data, _stats), do: :ok

  def persist_stats_snapshot(route_id, data, stats) when is_map(stats) do
    source_stream_id = Map.get(data, :source_stream_id)

    case StatsHistory.insert_snapshot(route_id, source_stream_id, stats) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        log_persist_error(route_id, reason)
    end
  end

  def persist_stats_snapshot(_route_id, _data, _stats), do: :ok

  def enrich_runtime_status(stats, data) when is_map(stats) and is_map(data) do
    case Map.get(data, :pipeline_status) do
      status when is_binary(status) and status != "" ->
        stats
        |> Map.put("schema_status", status)
        |> update_destinations_status(status)

      _ ->
        stats
    end
  end

  def enrich_runtime_status(stats, _data), do: stats

  defp ensure_stats_shape(stats, data) when is_map(stats) do
    stats
    |> ensure_source_map()
    |> ensure_destinations_list(data)
  end

  defp ensure_source_map(%{"source" => source} = stats) when is_map(source), do: stats

  defp ensure_source_map(stats) when is_map(stats) do
    Map.put(stats, "source", %{
      "bytes_in_per_sec" => 0,
      "bytes_in_total" => 0
    })
  end

  defp ensure_destinations_list(%{"destinations" => destinations} = stats, _data)
       when is_list(destinations),
       do: stats

  defp ensure_destinations_list(stats, data) when is_map(stats) do
    Map.put(stats, "destinations", baseline_destinations(data))
  end

  defp update_destinations_status(%{"destinations" => destinations} = stats, status)
       when is_list(destinations) do
    Map.put(
      stats,
      "destinations",
      Enum.map(destinations, fn
        %{} = destination -> Map.put(destination, "status", status)
        destination -> destination
      end)
    )
  end

  defp update_destinations_status(stats, _status), do: stats

  defp baseline_stats_snapshot(data) when is_map(data) do
    %{
      "source" => %{
        "bytes_in_per_sec" => 0,
        "bytes_in_total" => 0
      },
      "destinations" => baseline_destinations(data)
    }
  end

  defp baseline_destinations(%{route_record: route_record}) when is_map(route_record) do
    route_record
    |> Map.get("destinations", [])
    |> Enum.map(fn
      %{} = destination ->
        %{
          "id" => Map.get(destination, "id"),
          "name" => Map.get(destination, "name"),
          "schema" => Map.get(destination, "schema"),
          "bytes_out_per_sec" => 0,
          "bytes_out_total" => 0
        }

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp baseline_destinations(_data), do: []

  def log_persist_error(route_id, reason) do
    now = System.monotonic_time(:millisecond)

    last =
      try do
        :persistent_term.get(@persist_error_log_key, 0)
      rescue
        _ -> 0
      end

    if now - last >= @persist_error_log_interval_ms do
      try do
        :persistent_term.put(@persist_error_log_key, now)
      rescue
        _ -> :ok
      end

      Logger.error("StatsHistory insert failed route_id=#{inspect(route_id)}: #{inspect(reason)}")
    end

    :ok
  end

  def stats_to_metrics(_, _, export?) when export? != true, do: nil

  def stats_to_metrics(stats, data, true) do
    tags = %{
      type: "source",
      route_id: data.route_id,
      route_name: get_in(data, [:route_record, "name"]),
      source_stream_id: data.source_stream_id
    }

    cond do
      is_list(stats) ->
        Enum.each(stats, fn item -> stats_to_metrics(item, data, true) end)

      is_map(stats) ->
        {fields, nested} =
          Enum.reduce(stats, {%{}, []}, fn {key, value}, {fields, nested} ->
            cond do
              is_list(value) ->
                {fields, Enum.reverse(value, nested)}

              is_map(value) ->
                {fields, [value | nested]}

              true ->
                {Map.put(fields, norm_names(key), value), nested}
            end
          end)

        Metrics.event_fields(fields, tags)

        Enum.each(nested, fn item ->
          stats_to_metrics(item, data, true)
        end)

      true ->
        :ok
    end
  end

  def norm_names(name) do
    name
    |> String.replace("-", "_")
    |> String.downcase()
  end
end

defmodule HydraSrt.Stats.MetricSelector do
  @moduledoc false

  @spec select_rows(%{
          required(:route_id) => binary(),
          required(:stats) => map(),
          optional(:ts) => NaiveDateTime.t() | DateTime.t()
        }) :: [map()]
  def select_rows(%{route_id: route_id, stats: stats} = envelope)
      when is_binary(route_id) and is_map(stats) do
    ts = Map.get(envelope, :ts, DateTime.utc_now())
    metadata = Map.get(envelope, :metadata, %{})
    active_source_id = Map.get(metadata, :active_source_id)
    active_source_position = Map.get(metadata, :active_source_position)

    source_rows = source_rows(route_id, active_source_id, active_source_position, stats, ts)
    destination_rows = destination_bytes_out_rows(route_id, stats, ts)
    source_rows ++ destination_rows
  end

  def select_rows(_), do: []

  @spec source_rows(
          binary(),
          binary() | nil,
          integer() | nil,
          map(),
          NaiveDateTime.t() | DateTime.t()
        ) ::
          [map()]
  def source_rows(route_id, active_source_id, active_source_position, stats, ts)
      when is_binary(route_id) and is_map(stats) do
    []
    |> maybe_add_double_row(
      route_id,
      "route",
      route_id,
      "active_source_position",
      active_source_position,
      ts
    )
    |> maybe_add_double_row(
      route_id,
      "source",
      active_source_id,
      "bytes_in_per_sec",
      get_in(stats, ["source", "bytes_in_per_sec"]),
      ts
    )
    |> maybe_add_double_row(
      route_id,
      "source",
      active_source_id,
      "srt_packet_loss",
      get_in(stats, ["source", "srt", "packet-recv-loss"]),
      ts
    )
    |> maybe_add_double_row(
      route_id,
      "source",
      active_source_id,
      "srt_rtt_ms",
      get_in(stats, ["source", "srt", "rtt-ms"]),
      ts
    )
  end

  @spec destination_bytes_out_rows(binary(), map(), NaiveDateTime.t() | DateTime.t()) :: [map()]
  def destination_bytes_out_rows(route_id, stats, ts)
      when is_binary(route_id) and is_map(stats) do
    stats
    |> Map.get("destinations", [])
    |> Enum.flat_map(fn
      %{"id" => destination_id, "bytes_out_per_sec" => value}
      when is_binary(destination_id) and is_number(value) ->
        [
          %{
            ts: ts,
            route_id: route_id,
            entity_type: "destination",
            entity_id: destination_id,
            metric_key: "bytes_out_per_sec",
            value_type: "double",
            value_double: value * 1.0,
            value_bigint: nil,
            value_text: nil
          }
        ]

      _ ->
        []
    end)
  end

  defp maybe_add_double_row(rows, _route_id, _entity_type, _entity_id, _metric_key, value, _ts)
       when not is_number(value),
       do: rows

  defp maybe_add_double_row(rows, route_id, entity_type, entity_id, metric_key, value, ts)
       when is_binary(route_id) and is_binary(entity_type) and is_binary(metric_key) and
              is_number(value) do
    [
      %{
        ts: ts,
        route_id: route_id,
        entity_type: entity_type,
        entity_id: entity_id,
        metric_key: metric_key,
        value_type: "double",
        value_double: value * 1.0,
        value_bigint: nil,
        value_text: nil
      }
      | rows
    ]
  end
end

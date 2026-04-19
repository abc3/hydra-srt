defmodule HydraSrt.StatsProcessor do
  @moduledoc false

  require Logger

  alias HydraSrt.Metrics

  def process_stats_json(json, %{route_id: route_id} = data) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, stats} ->
        try do
          HydraSrt.StatsStore.put(route_id, stats)

          Phoenix.PubSub.broadcast(
            HydraSrt.PubSub,
            "stats:#{route_id}",
            {:stats, stats}
          )

          export? =
            get_in(data, [:route_record, "exportStats"]) and
              Application.get_env(:hydra_srt, :export_metrics?)

          stats_to_metrics(stats, data, export?)
        rescue
          error ->
            Logger.error(
              "Error processing stats: #{inspect(error)} route_id=#{inspect(route_id)} source_stream_id=#{inspect(data.source_stream_id)}"
            )
        end

      {error, _} ->
        Logger.error("Error decoding stats: #{inspect(error)} #{inspect(json)}")
    end

    :ok
  end

  def stats_to_metrics(_, _, false), do: nil

  def stats_to_metrics(stats, data, _) do
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

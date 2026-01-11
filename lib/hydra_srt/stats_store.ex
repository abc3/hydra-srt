defmodule HydraSrt.StatsStore do
  @moduledoc false

  @table :hydra_srt_latest_stats

  @spec ensure_table() :: :ok
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        _tid =
          :ets.new(@table, [
            :named_table,
            :set,
            :public,
            read_concurrency: true,
            write_concurrency: true
          ])

        :ok

      _ ->
        :ok
    end
  end

  @spec put(binary(), map()) :: :ok
  def put(route_id, stats) when is_binary(route_id) and is_map(stats) do
    :ok = ensure_table()

    :ets.insert(@table, {route_id, %{stats: stats, ts_ms: System.system_time(:millisecond)}})
    :ok
  end

  @spec get(binary()) :: {:ok, map()} | :error
  def get(route_id) when is_binary(route_id) do
    :ok = ensure_table()

    case :ets.lookup(@table, route_id) do
      [{^route_id, value}] -> {:ok, value}
      _ -> :error
    end
  end

  @spec all() :: %{optional(binary()) => map()}
  def all do
    :ok = ensure_table()

    :ets.tab2list(@table)
    |> Enum.reduce(%{}, fn {route_id, value}, acc -> Map.put(acc, route_id, value) end)
  end

  @spec aggregate_throughput() :: %{
          in_bytes_per_sec: number(),
          out_bytes_per_sec: number(),
          routes_with_stats: non_neg_integer()
        }
  def aggregate_throughput do
    :ok = ensure_table()

    entries = :ets.tab2list(@table)

    {in_sum, out_sum} =
      Enum.reduce(entries, {0, 0}, fn {_route_id, %{stats: stats}}, {in_acc, out_acc} ->
        {in_acc + extract_in_bytes_per_sec(stats), out_acc + extract_out_bytes_per_sec(stats)}
      end)

    %{
      in_bytes_per_sec: in_sum,
      out_bytes_per_sec: out_sum,
      routes_with_stats: length(entries)
    }
  end

  @spec extract_in_bytes_per_sec(map()) :: number()
  def extract_in_bytes_per_sec(stats) when is_map(stats) do
    case stats do
      %{"source" => %{"bytes_in_per_sec" => v}} when is_number(v) -> v
      _ -> 0
    end
  end

  @spec extract_out_bytes_per_sec(map()) :: number()
  def extract_out_bytes_per_sec(stats) when is_map(stats) do
    case stats do
      %{"destinations" => dests} when is_list(dests) ->
        Enum.reduce(dests, 0, fn d, acc ->
          case d do
            %{"bytes_out_per_sec" => v} when is_number(v) -> acc + v
            _ -> acc
          end
        end)

      _ ->
        0
    end
  end
end

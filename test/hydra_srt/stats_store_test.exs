defmodule HydraSrt.StatsStoreTest do
  use ExUnit.Case, async: true

  alias HydraSrt.StatsStore

  test "aggregate_throughput returns zeros when empty" do
    :ok = StatsStore.ensure_table()

    # best-effort cleanup: keep test isolated even if other tests touched the store
    try do
      :ets.delete_all_objects(:hydra_srt_latest_stats)
    rescue
      _ -> :ok
    end

    assert %{
             in_bytes_per_sec: 0,
             out_bytes_per_sec: 0,
             routes_with_stats: 0
           } = StatsStore.aggregate_throughput()
  end

  test "aggregate_throughput sums source in + destination out across routes" do
    :ok = StatsStore.ensure_table()

    try do
      :ets.delete_all_objects(:hydra_srt_latest_stats)
    rescue
      _ -> :ok
    end

    :ok =
      StatsStore.put("r1", %{
        "source" => %{"bytes_in_per_sec" => 10},
        "destinations" => [
          %{"id" => "d1", "bytes_out_per_sec" => 3},
          %{"id" => "d2", "bytes_out_per_sec" => 5}
        ]
      })

    :ok =
      StatsStore.put("r2", %{
        "source" => %{"bytes_in_per_sec" => 7},
        "destinations" => [%{"id" => "d3", "bytes_out_per_sec" => 2}]
      })

    assert %{
             in_bytes_per_sec: 17,
             out_bytes_per_sec: 10,
             routes_with_stats: 2
           } = StatsStore.aggregate_throughput()
  end
end

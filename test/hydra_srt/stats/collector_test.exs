defmodule HydraSrt.Stats.CollectorTest do
  use ExUnit.Case, async: true

  alias HydraSrt.Stats.Collector

  @interval_ms 10_000

  test "merge_rows keeps latest sample for same series in same 10s window" do
    row_1 = sample_row(~U[2026-01-01 00:00:01Z], "dest-1", 100.0)
    row_2 = sample_row(~U[2026-01-01 00:00:09Z], "dest-1", 200.0)

    rows_by_bucket_and_series =
      %{}
      |> Collector.merge_rows([row_1], @interval_ms)
      |> Collector.merge_rows([row_2], @interval_ms)

    assert map_size(rows_by_bucket_and_series) == 1
    assert rows_by_bucket_and_series |> Map.values() |> hd() |> Map.get(:value_double) == 200.0
  end

  test "merge_rows keeps separate entries for different 10s windows" do
    row_1 = sample_row(~U[2026-01-01 00:00:09Z], "dest-1", 100.0)
    row_2 = sample_row(~U[2026-01-01 00:00:10Z], "dest-1", 200.0)

    rows_by_bucket_and_series =
      %{}
      |> Collector.merge_rows([row_1], @interval_ms)
      |> Collector.merge_rows([row_2], @interval_ms)

    assert map_size(rows_by_bucket_and_series) == 2
  end

  test "merge_rows keeps separate entries for different destinations in same window" do
    row_1 = sample_row(~U[2026-01-01 00:00:05Z], "dest-1", 100.0)
    row_2 = sample_row(~U[2026-01-01 00:00:06Z], "dest-2", 200.0)

    rows_by_bucket_and_series =
      %{}
      |> Collector.merge_rows([row_1, row_2], @interval_ms)

    assert map_size(rows_by_bucket_and_series) == 2
  end

  test "flush_rows inserts one latest row per series per bucket" do
    row_1 = sample_row(~U[2026-01-01 00:00:01Z], "dest-1", 100.0)
    row_2 = sample_row(~U[2026-01-01 00:00:09Z], "dest-1", 200.0)
    row_3 = sample_row(~U[2026-01-01 00:00:06Z], "dest-2", 300.0)

    rows_by_bucket_and_series =
      %{}
      |> Collector.merge_rows([row_1], @interval_ms)
      |> Collector.merge_rows([row_2], @interval_ms)
      |> Collector.merge_rows([row_3], @interval_ms)

    assert map_size(rows_by_bucket_and_series) == 2

    assert {rows_after_flush, row_count_after_flush, :ok} =
             Collector.flush_rows(
               rows_by_bucket_and_series,
               map_size(rows_by_bucket_and_series),
               fn rows ->
                 send(self(), {:inserted_rows, rows})
                 :ok
               end
             )

    assert rows_after_flush == %{}
    assert row_count_after_flush == 0

    assert_receive {:inserted_rows, rows}
    assert length(rows) == 2
    assert Enum.any?(rows, &(&1.entity_id == "dest-1" and &1.value_double == 200.0))
    assert Enum.any?(rows, &(&1.entity_id == "dest-2" and &1.value_double == 300.0))
  end

  def sample_row(ts, destination_id, value) do
    %{
      ts: ts,
      route_id: "route-1",
      entity_type: "destination",
      entity_id: destination_id,
      metric_key: "bytes_out_per_sec",
      value_type: "double",
      value_double: value,
      value_bigint: nil,
      value_text: nil
    }
  end
end

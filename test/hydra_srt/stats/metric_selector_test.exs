defmodule HydraSrt.Stats.MetricSelectorTest do
  use ExUnit.Case, async: true

  alias HydraSrt.Stats.MetricSelector

  test "select_rows extracts source bytes_in_per_sec and destination bytes_out_per_sec" do
    envelope = %{
      route_id: "route-1",
      ts: ~U[2026-01-01 00:00:00Z],
      metadata: %{active_source_id: "source-1", active_source_position: 1},
      stats: %{
        "source" => %{
          "bytes_in_per_sec" => 191_572,
          "bytes_in_total" => 39_622_128,
          "srt" => %{"packet-recv-loss" => 0.01, "rtt-ms" => 12.5}
        },
        "destinations" => [
          %{"id" => "dest-1", "bytes_out_per_sec" => 186_684, "bytes_out_total" => 39_622_128},
          %{"id" => "dest-2", "bytes_out_per_sec" => 92_000},
          %{"id" => "dest-ignored"},
          %{"bytes_out_per_sec" => 11_111}
        ],
        "total-bytes-received" => 39_622_128
      }
    }

    rows = MetricSelector.select_rows(envelope)

    assert Enum.any?(rows, fn row ->
             row.entity_type == "route" and row.entity_id == "route-1" and
               row.metric_key == "active_source_position" and row.value_double == 1.0
           end)

    assert Enum.any?(rows, fn row ->
             row.entity_type == "source" and row.entity_id == "source-1" and
               row.metric_key == "bytes_in_per_sec" and row.value_double == 191_572.0
           end)

    assert Enum.any?(rows, fn row ->
             row.entity_type == "source" and row.entity_id == "source-1" and
               row.metric_key == "srt_packet_loss" and row.value_double == 0.01
           end)

    assert Enum.any?(rows, fn row ->
             row.entity_type == "source" and row.entity_id == "source-1" and
               row.metric_key == "srt_rtt_ms" and row.value_double == 12.5
           end)

    assert Enum.any?(rows, fn row ->
             row.entity_type == "destination" and row.entity_id == "dest-1" and
               row.metric_key == "bytes_out_per_sec" and row.value_double == 186_684.0
           end)

    assert Enum.any?(rows, fn row ->
             row.entity_type == "destination" and row.entity_id == "dest-2" and
               row.metric_key == "bytes_out_per_sec" and row.value_double == 92_000.0
           end)
  end

  test "select_rows returns empty list for invalid envelope" do
    assert MetricSelector.select_rows(%{}) == []
  end
end

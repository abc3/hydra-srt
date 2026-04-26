defmodule HydraSrt.Stats.MetricSelectorTest do
  use ExUnit.Case, async: true

  alias HydraSrt.Stats.MetricSelector

  test "select_rows extracts source bytes_in_per_sec and destination bytes_out_per_sec" do
    envelope = %{
      route_id: "route-1",
      ts: ~U[2026-01-01 00:00:00Z],
      stats: %{
        "source" => %{"bytes_in_per_sec" => 191_572, "bytes_in_total" => 39_622_128},
        "destinations" => [
          %{"id" => "dest-1", "bytes_out_per_sec" => 186_684, "bytes_out_total" => 39_622_128},
          %{"id" => "dest-2", "bytes_out_per_sec" => 92_000},
          %{"id" => "dest-ignored"},
          %{"bytes_out_per_sec" => 11_111}
        ],
        "total-bytes-received" => 39_622_128
      }
    }

    assert MetricSelector.select_rows(envelope) == [
             %{
               ts: ~U[2026-01-01 00:00:00Z],
               route_id: "route-1",
               entity_type: "source",
               entity_id: nil,
               metric_key: "bytes_in_per_sec",
               value_type: "double",
               value_double: 191_572.0,
               value_bigint: nil,
               value_text: nil
             },
             %{
               ts: ~U[2026-01-01 00:00:00Z],
               route_id: "route-1",
               entity_type: "destination",
               entity_id: "dest-1",
               metric_key: "bytes_out_per_sec",
               value_type: "double",
               value_double: 186_684.0,
               value_bigint: nil,
               value_text: nil
             },
             %{
               ts: ~U[2026-01-01 00:00:00Z],
               route_id: "route-1",
               entity_type: "destination",
               entity_id: "dest-2",
               metric_key: "bytes_out_per_sec",
               value_type: "double",
               value_double: 92_000.0,
               value_bigint: nil,
               value_text: nil
             }
           ]
  end

  test "select_rows returns empty list for invalid envelope" do
    assert MetricSelector.select_rows(%{}) == []
  end
end

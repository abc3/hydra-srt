defmodule HydraSrt.StatsProcessorTest do
  use ExUnit.Case, async: false

  alias HydraSrt.StatsProcessor
  alias HydraSrt.StatsStore

  setup do
    :ok = StatsStore.ensure_table()
    route_id = "route_#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(HydraSrt.PubSub, "stats:#{route_id}")
    {:ok, route_id: route_id}
  end

  test "process_stats_json stores stats and broadcasts them", %{route_id: route_id} do
    json = ~s({"source":{"bytes_in_per_sec":123},"destinations":[{"id":"d1","bytes_out_per_sec":10}]})

    assert :ok =
             StatsProcessor.process_stats_json(json, %{
               route_id: route_id,
               route_record: %{"name" => "test_route", "exportStats" => false},
               source_stream_id: "stream_1"
             })

    assert_receive {:stats, stats}
    assert %{"source" => %{"bytes_in_per_sec" => 123}} = stats
    assert {:ok, %{stats: ^stats}} = StatsStore.get(route_id)
  end

  test "stats_to_metrics accepts new payload shape" do
    stats = %{
      "source" => %{"bytes_in_per_sec" => 1234, "bytes_in_total" => 5678},
      "destinations" => [
        %{"id" => "d1", "name" => "dest1", "schema" => "UDP", "bytes_out_per_sec" => 10},
        %{"id" => "d2", "name" => "dest2", "schema" => "SRT", "bytes_out_per_sec" => 20}
      ],
      "connected-callers" => 1
    }

    data = %{
      route_id: "test_route",
      route_record: %{"name" => "test"},
      source_stream_id: "test_stream"
    }

    assert :ok = StatsProcessor.stats_to_metrics(stats, data, true)
  end

  test "norm_names normalizes metric names" do
    assert "test_metric" = StatsProcessor.norm_names("test-metric")
    assert "test_metric" = StatsProcessor.norm_names("TEST_METRIC")
    assert "test_metric" = StatsProcessor.norm_names("Test-Metric")
    assert "test.metric.name" = StatsProcessor.norm_names("test.metric.name")
  end
end

defmodule HydraSrt.StatsProcessorTest do
  use HydraSrt.DataCase, async: false

  import Ecto.Query

  alias HydraSrt.Repo
  alias HydraSrt.RouteStat
  alias HydraSrt.StatsProcessor
  alias HydraSrt.StatsStore

  setup do
    :ok = StatsStore.ensure_table()
    route_id = "route_#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(HydraSrt.PubSub, "stats:#{route_id}")
    {:ok, route_id: route_id}
  end

  test "process_stats_json stores stats and broadcasts them", %{route_id: route_id} do
    json =
      ~s({"source":{"bytes_in_per_sec":123},"destinations":[{"id":"d1","bytes_out_per_sec":10}]})

    assert :ok =
             StatsProcessor.process_stats_json(json, %{
               route_id: route_id,
               route_record: %{"name" => "test_route", "exportStats" => false},
               source_stream_id: "stream_1",
               pipeline_status: "processing"
             })

    assert_receive {:stats, stats}

    assert %{
             "source" => %{"bytes_in_per_sec" => 123},
             "schema_status" => "processing",
             "destinations" => [%{"id" => "d1", "status" => "processing"}]
           } = stats

    assert {:ok, %{stats: ^stats}} = StatsStore.get(route_id)

    assert wait_for(fn ->
             Repo.one(from(r in RouteStat, where: r.route_id == ^route_id))
           end)
  end

  test "process_stats_json logs decode error and does not crash", %{route_id: route_id} do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 StatsProcessor.process_stats_json("{not json", %{
                   route_id: route_id,
                   route_record: %{},
                   source_stream_id: "s"
                 })
      end)

    assert log =~ "Error decoding stats"
  end

  test "process_pipeline_status stores and broadcasts status-only snapshots", %{
    route_id: route_id
  } do
    assert :ok =
             StatsProcessor.process_pipeline_status(%{
               route_id: route_id,
               route_record: %{
                 "name" => "test_route",
                 "exportStats" => false,
                 "destinations" => [
                   %{"id" => "d1", "name" => "Destination 1", "schema" => "UDP"}
                 ]
               },
               source_stream_id: "stream_1",
               pipeline_status: "starting"
             })

    assert_receive {:stats, stats}
    assert stats["schema_status"] == "starting"
    assert stats["source"] == %{"bytes_in_per_sec" => 0, "bytes_in_total" => 0}

    assert stats["destinations"] == [
             %{
               "id" => "d1",
               "name" => "Destination 1",
               "schema" => "UDP",
               "bytes_out_per_sec" => 0,
               "bytes_out_total" => 0,
               "status" => "starting"
             }
           ]

    assert {:ok, %{stats: ^stats}} = StatsStore.get(route_id)

    persisted =
      wait_for(fn ->
        Repo.one(from(r in RouteStat, where: r.route_id == ^route_id))
      end)

    assert persisted.stats["schema_status"] == "starting"
    assert persisted.stats["source"] == %{"bytes_in_per_sec" => 0, "bytes_in_total" => 0}
  end

  test "process_pipeline_status preserves existing throughput fields in latest and persisted stats",
       %{
         route_id: route_id
       } do
    base_stats = %{
      "source" => %{"bytes_in_per_sec" => 321, "bytes_in_total" => 654},
      "destinations" => [%{"id" => "d1", "bytes_out_per_sec" => 12, "bytes_out_total" => 34}]
    }

    :ok = StatsStore.put(route_id, base_stats)

    assert :ok =
             StatsProcessor.process_pipeline_status(%{
               route_id: route_id,
               route_record: %{"name" => "test_route", "exportStats" => false},
               source_stream_id: "stream_1",
               pipeline_status: "reconnecting"
             })

    assert_receive {:stats, stats}

    assert %{
             "schema_status" => "reconnecting",
             "source" => %{"bytes_in_per_sec" => 321, "bytes_in_total" => 654},
             "destinations" => [
               %{
                 "id" => "d1",
                 "bytes_out_per_sec" => 12,
                 "bytes_out_total" => 34,
                 "status" => "reconnecting"
               }
             ]
           } = stats

    assert {:ok, %{stats: ^stats}} = StatsStore.get(route_id)

    persisted =
      wait_for(fn ->
        Repo.one(
          from(r in RouteStat,
            where: r.route_id == ^route_id,
            order_by: [desc: r.inserted_at],
            limit: 1
          )
        )
      end)

    assert persisted.stats == stats
  end

  test "process_stats_json carries forward pipeline status into persisted history snapshots", %{
    route_id: route_id
  } do
    json =
      ~s({"source":{"bytes_in_per_sec":777},"destinations":[{"id":"d1","bytes_out_per_sec":22}]})

    assert :ok =
             StatsProcessor.process_stats_json(json, %{
               route_id: route_id,
               route_record: %{"name" => "test_route", "exportStats" => false},
               source_stream_id: "stream_1",
               pipeline_status: "failed"
             })

    assert_receive {:stats, stats}
    assert stats["schema_status"] == "failed"
    assert get_in(stats, ["destinations", Access.at(0), "status"]) == "failed"

    persisted =
      wait_for(fn ->
        Repo.one(
          from(r in RouteStat,
            where: r.route_id == ^route_id,
            order_by: [desc: r.inserted_at],
            limit: 1
          )
        )
      end)

    assert persisted.stats["schema_status"] == "failed"
    assert get_in(persisted.stats, ["destinations", Access.at(0), "status"]) == "failed"
    assert get_in(persisted.stats, ["source", "bytes_in_per_sec"]) == 777
  end

  def wait_for(fun, attempts \\ 50)
  def wait_for(_fun, 0), do: nil

  def wait_for(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(20)
        wait_for(fun, attempts - 1)

      value ->
        value
    end
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

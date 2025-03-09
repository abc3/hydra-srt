defmodule HydraSrt.UnixSockHandlerTest do
  use ExUnit.Case
  alias HydraSrt.UnixSockHandler

  test "callback_mode returns handle_event_function" do
    assert UnixSockHandler.callback_mode() == [:handle_event_function]
  end

  test "init returns ignore" do
    assert :ignore = UnixSockHandler.init([])
  end

  test "handle_event with route_id message" do
    route_id = "test_route"
    message = {:tcp, nil, "route_id:" <> route_id}
    state = :exchange
    data = %{sock: nil, trans: nil, source_stream_id: nil, route_id: nil, route_record: nil}

    assert {:keep_state, new_data} = UnixSockHandler.handle_event(:info, message, state, data)
    assert new_data.route_id == route_id
  end

  test "handle_event with empty route_id message" do
    message = {:tcp, nil, "route_id:"}
    state = :exchange
    data = %{sock: nil, trans: nil, source_stream_id: nil, route_id: nil, route_record: nil}

    assert {:keep_state, new_data} = UnixSockHandler.handle_event(:info, message, state, data)
    assert new_data.route_id == ""
  end

  test "handle_event with stats_json message and exportStats true" do
    json = ~s({"bytes_sent": 1000, "bytes_received": 2000})
    message = {:tcp, nil, "stats_json:" <> json}
    state = :exchange

    data = %{
      sock: nil,
      trans: nil,
      source_stream_id: "test_stream",
      route_id: "test_route",
      route_record: %{"exportStats" => true, "name" => "test"}
    }

    assert :keep_state_and_data = UnixSockHandler.handle_event(:info, message, state, data)
  end

  test "handle_event with invalid stats_json message" do
    json = ~s({invalid_json)
    message = {:tcp, nil, "stats_json:" <> json}
    state = :exchange

    data = %{
      sock: nil,
      trans: nil,
      source_stream_id: "test_stream",
      route_id: "test_route",
      route_record: %{"exportStats" => true, "name" => "test"}
    }

    assert :keep_state_and_data = UnixSockHandler.handle_event(:info, message, state, data)
  end

  test "handle_event with stats_json message and exportStats false" do
    json = ~s({"bytes_sent": 1000, "bytes_received": 2000})
    message = {:tcp, nil, "stats_json:" <> json}
    state = :exchange

    data = %{
      sock: nil,
      trans: nil,
      source_stream_id: "test_stream",
      route_id: "test_route",
      route_record: %{"exportStats" => false}
    }

    assert :keep_state_and_data = UnixSockHandler.handle_event(:info, message, state, data)
  end

  test "handle_event with stats_json message and missing route_record" do
    json = ~s({"bytes_sent": 1000, "bytes_received": 2000})
    message = {:tcp, nil, "stats_json:" <> json}
    state = :exchange

    data = %{
      sock: nil,
      trans: nil,
      source_stream_id: "test_stream",
      route_id: "test_route",
      route_record: nil
    }

    assert :keep_state_and_data = UnixSockHandler.handle_event(:info, message, state, data)
  end

  test "handle_event with stats_source_stream_id message" do
    stream_id = "test_stream"
    message = {:tcp, nil, "stats_source_stream_id:" <> stream_id}
    state = :exchange
    data = %{sock: nil, trans: nil, source_stream_id: nil, route_id: nil, route_record: nil}

    assert {:keep_state, new_data} = UnixSockHandler.handle_event(:info, message, state, data)
    assert new_data.source_stream_id == stream_id
  end

  test "handle_event with empty stats_source_stream_id message" do
    message = {:tcp, nil, "stats_source_stream_id:"}
    state = :exchange
    data = %{sock: nil, trans: nil, source_stream_id: nil, route_id: nil, route_record: nil}

    assert {:keep_state, new_data} = UnixSockHandler.handle_event(:info, message, state, data)
    assert new_data.source_stream_id == ""
  end

  test "handle_event with undefined message" do
    message = {:tcp, nil, "undefined_message"}
    state = :exchange
    data = %{sock: nil, trans: nil, source_stream_id: nil, route_id: nil, route_record: nil}

    assert :keep_state_and_data = UnixSockHandler.handle_event(:info, message, state, data)
  end

  test "handle_event with non-tcp message" do
    message = {:other, nil, "some_message"}
    state = :exchange
    data = %{sock: nil, trans: nil, source_stream_id: nil, route_id: nil, route_record: nil}

    assert :keep_state_and_data = UnixSockHandler.handle_event(:info, message, state, data)
  end

  test "terminate returns ok" do
    assert :ok = UnixSockHandler.terminate(:normal, :exchange, %{})
  end

  test "terminate with different reasons" do
    reasons = [:normal, :shutdown, :timeout, {:error, "test"}]

    for reason <- reasons do
      assert :ok = UnixSockHandler.terminate(reason, :exchange, %{})
    end
  end

  test "stats_to_metrics with nested data" do
    stats = %{
      "nested" => [
        %{"value" => 100},
        %{"value" => 200}
      ],
      "simple" => 300
    }

    data = %{
      route_id: "test_route",
      route_record: %{"name" => "test"},
      source_stream_id: "test_stream"
    }

    UnixSockHandler.stats_to_metrics(stats, data)
  end

  test "stats_to_metrics with deeply nested data" do
    stats = %{
      "level1" => %{
        "level2" => [
          %{"level3" => %{"value" => 100}},
          %{"level3" => %{"value" => 200}}
        ]
      },
      "simple" => 300
    }

    data = %{
      route_id: "test_route",
      route_record: %{"name" => "test"},
      source_stream_id: "test_stream"
    }

    UnixSockHandler.stats_to_metrics(stats, data)
  end

  test "norm_names normalizes metric names" do
    assert "test_metric" = UnixSockHandler.norm_names("test-metric")
    assert "test_metric" = UnixSockHandler.norm_names("TEST_METRIC")
    assert "test_metric" = UnixSockHandler.norm_names("Test-Metric")
  end

  test "norm_names with various special characters" do
    assert "test_metric_name" = UnixSockHandler.norm_names("test-metric-name")
    assert "test_metric_name" = UnixSockHandler.norm_names("test.metric.name")
    assert "test_metric_name" = UnixSockHandler.norm_names("test/metric/name")
    assert "test_metric_name" = UnixSockHandler.norm_names("test:metric:name")
  end
end

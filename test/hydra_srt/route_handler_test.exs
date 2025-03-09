defmodule HydraSrt.RouteHandlerTest do
  use ExUnit.Case
  alias HydraSrt.RouteHandler

  test "source_from_record with valid SRT schema" do
    record = %{
      "schema" => "SRT",
      "schema_options" => %{
        "localaddress" => "127.0.0.1",
        "localport" => 4201,
        "mode" => "listener",
        "latency" => 200,
        "auto-reconnect" => true,
        "keep-listening" => true
      }
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["type"] == "srtsrc"
    assert source["uri"] =~ "srt://127.0.0.1:4201"
    assert source["uri"] =~ "mode=listener"
    assert source["latency"] == 200
    assert source["auto-reconnect"] == true
    assert source["keep-listening"] == true
  end

  test "source_from_record with valid UDP schema" do
    record = %{
      "schema" => "UDP",
      "schema_options" => %{
        "address" => "127.0.0.1",
        "port" => 4201,
        "buffer-size" => 65536,
        "mtu" => 1500
      }
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["type"] == "udpsrc"
    assert source["address"] == "127.0.0.1"
    assert source["port"] == 4201
    assert source["buffer-size"] == 65536
    assert source["mtu"] == 1500
  end

  test "source_from_record with invalid schema" do
    record = %{
      "schema" => "INVALID",
      "schema_options" => %{}
    }

    assert {:error, :invalid_source} = RouteHandler.source_from_record(record)
  end

  test "route_data_to_params with valid route data" do
    route_id = "test_route"

    route = %{
      "schema" => "SRT",
      "schema_options" => %{
        "localaddress" => "127.0.0.1",
        "localport" => 4201,
        "mode" => "listener"
      },
      "destinations" => [
        %{
          "schema" => "SRT",
          "schema_options" => %{
            "localaddress" => "127.0.0.1",
            "localport" => 4202,
            "mode" => "listener"
          }
        }
      ]
    }

    assert {:ok, params} = RouteHandler.route_data_to_params(route_id)
    assert is_map(params)
    assert Map.has_key?(params, "source")
    assert Map.has_key?(params, "sinks")
    assert is_list(params["sinks"])
  end

  test "callback_mode returns handle_event_function" do
    assert RouteHandler.callback_mode() == [:handle_event_function]
  end

  test "init sets up initial state" do
    args = %{id: "test_route"}

    assert {:ok, :start, %{id: "test_route", port: nil}, {:next_event, :internal, :start}} =
             RouteHandler.init(args)
  end

  test "terminate handles port cleanup" do
    state = :started
    data = %{port: nil, id: "test_route"}
    assert :ok = RouteHandler.terminate(:normal, state, data)
  end
end

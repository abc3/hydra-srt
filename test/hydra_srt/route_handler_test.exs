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

  test "source_from_record with SRT schema and passphrase" do
    record = %{
      "schema" => "SRT",
      "schema_options" => %{
        "localaddress" => "127.0.0.1",
        "localport" => 4201,
        "mode" => "listener",
        "passphrase" => "secret",
        "pbkeylen" => 16
      }
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["type"] == "srtsrc"
    assert source["uri"] =~ "srt://127.0.0.1:4201"
    assert source["uri"] =~ "mode=listener"
    assert source["uri"] =~ "passphrase=secret"
    assert source["uri"] =~ "pbkeylen=16"
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

  test "source_from_record with UDP schema and minimal options" do
    record = %{
      "schema" => "UDP",
      "schema_options" => %{
        "address" => "127.0.0.1",
        "port" => 4201
      }
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["type"] == "udpsrc"
    assert source["address"] == "127.0.0.1"
    assert source["port"] == 4201
  end

  test "source_from_record with invalid schema" do
    record = %{
      "schema" => "INVALID",
      "schema_options" => %{}
    }

    assert {:error, :invalid_source} = RouteHandler.source_from_record(record)
  end

  test "source_from_record with missing schema_options" do
    record = %{"schema" => "SRT"}
    assert {:error, :invalid_source} = RouteHandler.source_from_record(record)
  end

  test "sink_from_record includes hydra destination metadata for SRT" do
    record = %{
      "id" => "dest1",
      "name" => "Destination 1",
      "schema" => "SRT",
      "schema_options" => %{
        "localaddress" => "127.0.0.1",
        "localport" => 4202,
        "mode" => "caller"
      }
    }

    assert {:ok, sink} = RouteHandler.sink_from_record(record)
    assert sink["type"] == "srtsink"
    assert sink["hydra_destination_id"] == "dest1"
    assert sink["hydra_destination_name"] == "Destination 1"
    assert sink["hydra_destination_schema"] == "SRT"
  end

  test "sink_from_record includes hydra destination metadata for UDP" do
    record = %{
      "id" => "dest2",
      "name" => "Destination 2",
      "schema" => "UDP",
      "schema_options" => %{
        "host" => "127.0.0.1",
        "port" => 4203
      }
    }

    assert {:ok, sink} = RouteHandler.sink_from_record(record)
    assert sink["type"] == "udpsink"
    assert sink["hydra_destination_id"] == "dest2"
    assert sink["hydra_destination_name"] == "Destination 2"
    assert sink["hydra_destination_schema"] == "UDP"
  end

  test "callback_mode returns handle_event_function" do
    assert RouteHandler.callback_mode() == [:handle_event_function]
  end
end

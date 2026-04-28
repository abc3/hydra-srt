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

  test "build_srt_uri uses remote address and port in caller mode" do
    opts = %{
      "mode" => "caller",
      "address" => "198.51.100.20",
      "port" => 4209,
      "localaddress" => "10.0.0.10",
      "localport" => 4201
    }

    assert RouteHandler.build_srt_uri(opts) == "srt://198.51.100.20:4209?mode=caller"
  end

  test "strip_cidr_suffix removes netmask from discovered interface ip" do
    assert RouteHandler.strip_cidr_suffix("172.20.20.12/24") == "172.20.20.12"
    assert RouteHandler.strip_cidr_suffix("fe80::1%en0/64") == "fe80::1%en0"
    assert RouteHandler.strip_cidr_suffix("10.0.0.5") == "10.0.0.5"
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

  test "sink_from_record keeps udp bind and multicast interface properties" do
    record = %{
      "id" => "dest3",
      "name" => "Destination 3",
      "schema" => "UDP",
      "schema_options" => %{
        "host" => "239.1.1.1",
        "port" => 5004,
        "bind-address" => "10.10.0.2",
        "multicast-iface" => "eno2"
      }
    }

    assert {:ok, sink} = RouteHandler.sink_from_record(record)
    assert sink["type"] == "udpsink"
    assert sink["host"] == "239.1.1.1"
    assert sink["port"] == 5004
    assert sink["bind-address"] == "10.10.0.2"
    assert sink["multicast-iface"] == "eno2"
  end

  test "sinks_from_record skips disabled destinations" do
    record = %{
      "destinations" => [
        %{
          "id" => "dest-enabled",
          "enabled" => true,
          "name" => "Enabled destination",
          "schema" => "UDP",
          "schema_options" => %{
            "host" => "127.0.0.1",
            "port" => 4203
          }
        },
        %{
          "id" => "dest-disabled",
          "enabled" => false,
          "name" => "Disabled destination",
          "schema" => "UDP",
          "schema_options" => %{
            "host" => "127.0.0.1",
            "port" => 4204
          }
        }
      ]
    }

    assert {:ok, [sink]} = RouteHandler.sinks_from_record(record)
    assert sink["hydra_destination_id"] == "dest-enabled"
  end

  test "sinks_from_record includes only explicitly enabled destinations" do
    record = %{
      "destinations" => [
        %{
          "id" => "dest-enabled",
          "enabled" => true,
          "name" => "Enabled destination",
          "schema" => "UDP",
          "schema_options" => %{
            "host" => "127.0.0.1",
            "port" => 4203
          }
        },
        %{
          "id" => "dest-missing-enabled",
          "name" => "Missing enabled flag",
          "schema" => "UDP",
          "schema_options" => %{
            "host" => "127.0.0.1",
            "port" => 4204
          }
        },
        %{
          "id" => "dest-nil-enabled",
          "enabled" => nil,
          "name" => "Nil enabled flag",
          "schema" => "UDP",
          "schema_options" => %{
            "host" => "127.0.0.1",
            "port" => 4205
          }
        }
      ]
    }

    assert {:ok, [sink]} = RouteHandler.sinks_from_record(record)
    assert sink["hydra_destination_id"] == "dest-enabled"
  end

  test "parse_native_json_line detects pipeline status events" do
    assert {:pipeline_status, "processing", nil} =
             RouteHandler.parse_native_json_line(
               ~s({"event":"pipeline_status","status":"processing"})
             )
  end

  test "parse_native_json_line keeps stats payloads separate" do
    assert {:stats, %{"source" => %{"bytes_in_per_sec" => 123}, "destinations" => []}} =
             RouteHandler.parse_native_json_line(
               ~s({"source":{"bytes_in_per_sec":123},"destinations":[]})
             )
  end

  test "stats_events includes snapshot and extracts input and destination output bytes per second" do
    stats = %{
      "source" => %{"bytes_in_per_sec" => 191_572},
      "destinations" => [
        %{"id" => "dest-1", "bytes_out_per_sec" => 186_684},
        %{"id" => "dest-2", "bytes_out_per_sec" => 92_000},
        %{"id" => "dest-ignored"},
        %{"bytes_out_per_sec" => 1_000}
      ]
    }

    assert RouteHandler.stats_events(stats, "route-1") == [
             %{
               route_id: "route-1",
               metric: "snapshot",
               stats: stats
             },
             %{
               route_id: "route-1",
               direction: "in",
               metric: "bytes_per_sec",
               value: 191_572
             },
             %{
               route_id: "route-1",
               destination_id: "dest-1",
               direction: "out",
               metric: "bytes_per_sec",
               value: 186_684
             },
             %{
               route_id: "route-1",
               destination_id: "dest-2",
               direction: "out",
               metric: "bytes_per_sec",
               value: 92_000
             }
           ]
  end

  test "publish_stats broadcasts snapshot and bytes per second on stats topics" do
    Phoenix.PubSub.subscribe(HydraSrt.PubSub, "stats")

    stats = %{
      "source" => %{"bytes_in_per_sec" => 191_572},
      "destinations" => [%{"id" => "dest-1", "bytes_out_per_sec" => 186_684}]
    }

    assert :ok =
             RouteHandler.publish_stats("route-1", stats)

    assert_receive {:stats,
                    %{
                      route_id: "route-1",
                      metric: "snapshot",
                      stats: ^stats
                    }}

    assert_receive {:stats,
                    %{
                      route_id: "route-1",
                      direction: "in",
                      metric: "bytes_per_sec",
                      value: 191_572
                    }}

    assert_receive {:stats,
                    %{
                      route_id: "route-1",
                      destination_id: "dest-1",
                      direction: "out",
                      metric: "bytes_per_sec",
                      value: 186_684
                    }}
  end

  test "parse_native_json_line keeps status reason when present" do
    assert {:pipeline_status, "stopped", "failure"} =
             RouteHandler.parse_native_json_line(
               ~s({"event":"pipeline_status","status":"stopped","reason":"failure"})
             )
  end

  test "normalize_runtime_status ignores stopped failure event to preserve failed state" do
    assert :ignore = RouteHandler.normalize_runtime_status("stopped", "failure")
    assert {:update, "failed"} = RouteHandler.normalize_runtime_status("failed", "runtime_error")
    assert {:update, "processing"} = RouteHandler.normalize_runtime_status("processing", nil)
  end

  test "failed runtime status is preserved when binary exits with non-zero code" do
    # Rust emits `failed` then immediately `stopped/failure` before the OS process dies.
    # The two parse steps produce distinct tuples...
    assert {:pipeline_status, "failed", "runtime_error"} =
             RouteHandler.parse_native_json_line(
               ~s({"event":"pipeline_status","status":"failed","reason":"runtime_error"})
             )

    assert {:pipeline_status, "stopped", "failure"} =
             RouteHandler.parse_native_json_line(
               ~s({"event":"pipeline_status","status":"stopped","reason":"failure"})
             )

    # ...and the normalization layer updates on the first event but ignores the second,
    # so the DB value stays "failed" rather than being overwritten with "stopped".
    assert {:update, "failed"} = RouteHandler.normalize_runtime_status("failed", "runtime_error")
    assert :ignore = RouteHandler.normalize_runtime_status("stopped", "failure")
  end
end

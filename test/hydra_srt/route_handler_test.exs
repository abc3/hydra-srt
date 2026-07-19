defmodule HydraSrt.RouteHandlerTest do
  use ExUnit.Case
  alias HydraSrt.RouteHandler

  defmodule TestSystemInterfaces do
    def discover do
      {:ok,
       [
         %{"sys_name" => "en0", "ip" => "172.20.20.12/24"},
         %{"sys_name" => "en1", "ip" => "10.10.0.4"}
       ]}
    end
  end

  defmodule EmptySystemInterfaces do
    def discover, do: {:ok, []}
  end

  defmodule FailingSystemInterfaces do
    def discover, do: {:error, :ifconfig_failed}
  end

  defmodule TestDb do
    def get_interface_by_sys_name("en0"), do: {:ok, %{"sys_name" => "en0", "ip" => "10.0.0.2/24"}}
    def get_interface_by_sys_name("en9"), do: {:ok, %{"sys_name" => "en9", "ip" => "192.0.2.10"}}
    def get_interface_by_sys_name(_), do: {:error, :not_found}
  end

  defmodule MissingTestDb do
    def get_interface_by_sys_name(_), do: {:error, :not_found}
  end

  # Full RouteHandler data map matching init/1 (including W3b recovery keys).
  @spec base_route_data(map()) :: map()
  def base_route_data(overrides \\ %{}) when is_map(overrides) do
    Map.merge(
      %{
        id: "route-base",
        port: nil,
        route: %{},
        port_buffer: "",
        shutdown_reason: nil,
        active_source_id: nil,
        last_manual_source_id: nil,
        process_instance_id: nil,
        endpoint_health: %{},
        route_terminal: nil,
        source_loss_since_ms: nil,
        source_loss_signal: nil,
        cooldown_until: nil,
        primary_stable_since_ms: nil,
        last_primary_probe_ms: nil,
        primary_probe_inflight?: false,
        retry_scheduled?: false,
        retry_attempt: 0,
        retry_prev_backoff_ms: nil,
        retry_circuit_open?: false,
        recovery_blocked?: false,
        recovering?: false
      },
      overrides
    )
  end

  test "source_from_record with valid SRT schema" do
    record = %{
      "schema" => "SRT",
      "localaddress" => "127.0.0.1",
      "localport" => 4201,
      "mode" => "listener",
      "latency" => 200,
      "auto_reconnect" => true,
      "keep_listening" => true,
      "limit_access" => true,
      "allowed_list" => ["127.0.0.1", "10.10.0.0/16"],
      "denied_list" => ["192.0.2.10"]
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["kind"] == "srt"
    srt = source["srt"]
    assert srt["uri"] =~ "srt://127.0.0.1:4201"
    assert srt["uri"] =~ "mode=listener"
    assert srt["mode"] == "listener"
    assert srt["latency"] == 200
    assert srt["auto_reconnect"] == true
    assert srt["keep_listening"] == true
    assert srt["localaddress"] == "127.0.0.1"
    assert srt["localport"] == 4201

    assert srt["access"] == %{
             "limit" => true,
             "allowed" => ["127.0.0.1", "10.10.0.0/16"],
             "denied" => ["192.0.2.10"]
           }

    refute Map.has_key?(srt, "streamid")
  end

  test "source_from_record does not pass access ranges when limit_access is false" do
    record = %{
      "schema" => "SRT",
      "localaddress" => "127.0.0.1",
      "localport" => 4201,
      "mode" => "listener",
      "limit_access" => false,
      "allowed_list" => ["127.0.0.1"],
      "denied_list" => ["192.0.2.10"]
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    refute Map.has_key?(source["srt"], "access")
  end

  test "source_from_record with SRT schema and passphrase" do
    record = %{
      "schema" => "SRT",
      "localaddress" => "127.0.0.1",
      "localport" => 4201,
      "mode" => "listener",
      "passphrase" => "secret",
      "pbkeylen" => 16
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["kind"] == "srt"
    srt = source["srt"]
    assert srt["uri"] =~ "srt://127.0.0.1:4201"
    assert srt["uri"] =~ "mode=listener"
    assert srt["uri"] =~ "passphrase=secret"
    assert srt["uri"] =~ "pbkeylen=16"
    assert srt["passphrase"] == "secret"
    assert srt["pbkeylen"] == 16
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

  test "build_srt_uri encodes streamid with SRT authentication options" do
    opts = %{
      "mode" => "caller",
      "address" => "198.51.100.20",
      "port" => 4209,
      "streamid" => "#!::r=channel",
      "passphrase" => "some_pass_1",
      "pbkeylen" => 16
    }

    uri = RouteHandler.build_srt_uri(opts)
    query = URI.parse(uri).query |> URI.decode_query()

    assert URI.parse(uri).host == "198.51.100.20"
    assert URI.parse(uri).port == 4209

    assert query == %{
             "mode" => "caller",
             "streamid" => "#!::r=channel",
             "passphrase" => "some_pass_1",
             "pbkeylen" => "16"
           }
  end

  test "build_srt_uri supports streamid in rendezvous mode" do
    uri =
      RouteHandler.build_srt_uri(%{
        "mode" => "rendezvous",
        "address" => "198.51.100.20",
        "port" => 4209,
        "streamid" => "channel"
      })

    assert URI.decode_query(URI.parse(uri).query) == %{
             "mode" => "rendezvous",
             "streamid" => "channel"
           }
  end

  test "build_srt_uri omits nil and empty streamid" do
    base = %{"mode" => "caller", "address" => "198.51.100.20", "port" => 4209}

    for streamid <- [nil, ""] do
      uri = RouteHandler.build_srt_uri(Map.put(base, "streamid", streamid))
      refute URI.decode_query(URI.parse(uri).query) |> Map.has_key?("streamid")
    end
  end

  test "build_srt_uri omits preserved streamid in listener mode" do
    uri =
      RouteHandler.build_srt_uri(%{
        "mode" => "listener",
        "localaddress" => "127.0.0.1",
        "localport" => 4201,
        "streamid" => "#!::r=preserved"
      })

    refute URI.decode_query(URI.parse(uri).query) |> Map.has_key?("streamid")
  end

  test "source_from_record does not send preserved streamid to a listener pipeline" do
    record = %{
      "schema" => "SRT",
      "mode" => "listener",
      "localaddress" => "127.0.0.1",
      "localport" => 4201,
      "streamid" => "#!::r=preserved"
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    refute Map.has_key?(source["srt"], "streamid")
    refute URI.decode_query(URI.parse(source["srt"]["uri"]).query) |> Map.has_key?("streamid")
  end

  test "source_from_record sends caller streamid through URI and typed payload" do
    record = %{
      "schema" => "SRT",
      "mode" => "caller",
      "address" => "198.51.100.20",
      "port" => 4209,
      "streamid" => "#!::r=channel"
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["srt"]["streamid"] == "#!::r=channel"
    assert URI.decode_query(URI.parse(source["srt"]["uri"]).query)["streamid"] == "#!::r=channel"
  end

  test "strip_cidr_suffix removes netmask from discovered interface ip" do
    assert RouteHandler.strip_cidr_suffix("172.20.20.12/24") == "172.20.20.12"
    assert RouteHandler.strip_cidr_suffix("fe80::1%en0/64") == "fe80::1%en0"
    assert RouteHandler.strip_cidr_suffix("10.0.0.5") == "10.0.0.5"
  end

  test "resolve_interface_bind_ip prefers live system interface ip over DB value" do
    Application.put_env(:hydra_srt, :system_interfaces_module, TestSystemInterfaces)
    Application.put_env(:hydra_srt, :db_module, TestDb)

    on_exit(fn ->
      Application.delete_env(:hydra_srt, :system_interfaces_module)
      Application.delete_env(:hydra_srt, :db_module)
    end)

    assert {:ok, "172.20.20.12"} = RouteHandler.resolve_interface_bind_ip("en0")
  end

  test "resolve_interface_bind_ip falls back to DB when system lookup misses interface" do
    Application.put_env(:hydra_srt, :system_interfaces_module, EmptySystemInterfaces)
    Application.put_env(:hydra_srt, :db_module, TestDb)

    on_exit(fn ->
      Application.delete_env(:hydra_srt, :system_interfaces_module)
      Application.delete_env(:hydra_srt, :db_module)
    end)

    assert {:ok, "192.0.2.10"} = RouteHandler.resolve_interface_bind_ip("en9")
  end

  test "resolve_interface_bind_ip falls back to DB when system discovery fails" do
    Application.put_env(:hydra_srt, :system_interfaces_module, FailingSystemInterfaces)
    Application.put_env(:hydra_srt, :db_module, TestDb)

    on_exit(fn ->
      Application.delete_env(:hydra_srt, :system_interfaces_module)
      Application.delete_env(:hydra_srt, :db_module)
    end)

    assert {:ok, "10.0.0.2"} = RouteHandler.resolve_interface_bind_ip("en0")
  end

  test "source_from_record with valid UDP schema" do
    record = %{
      "schema" => "UDP",
      "address" => "127.0.0.1",
      "port" => 4201,
      "buffer-size" => 65536,
      "mtu" => 1500
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["kind"] == "udp"
    assert source["udp"] == %{"address" => "127.0.0.1", "port" => 4201}
    refute Map.has_key?(source["udp"], "buffer-size")
    refute Map.has_key?(source["udp"], "mtu")
  end

  test "source_from_record with UDP schema and minimal options" do
    record = %{
      "schema" => "UDP",
      "address" => "127.0.0.1",
      "port" => 4201
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["kind"] == "udp"
    assert source["udp"]["address"] == "127.0.0.1"
    assert source["udp"]["port"] == 4201
  end

  test "source_from_record normalizes UDP host to udpsrc address" do
    record = %{
      "schema" => "UDP",
      "host" => "127.0.0.1",
      "port" => 4201
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["kind"] == "udp"
    assert source["udp"]["address"] == "127.0.0.1"
    refute Map.has_key?(source["udp"], "host")
  end

  test "source_from_record emits explicit UDP multicast options" do
    record = %{
      "schema" => "UDP",
      "address" => "239.1.1.1",
      "port" => 5000,
      "multicast" => true,
      "multicast_iface" => "eno2"
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["kind"] == "udp"

    assert source["udp"] == %{
             "address" => "239.1.1.1",
             "port" => 5000,
             "auto_multicast" => true,
             "multicast_iface" => "eno2"
           }
  end

  test "source_from_record with RTP schema" do
    record = %{
      "schema" => "RTP",
      "address" => "127.0.0.1",
      "port" => 5004
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["kind"] == "rtp"
    assert source["rtp"] == %{"address" => "127.0.0.1", "port" => 5004}
    refute Map.has_key?(source, "hydra_source_schema")
  end

  test "source_from_record keeps RTP depay marker with multicast options" do
    Application.put_env(:hydra_srt, :system_interfaces_module, EmptySystemInterfaces)
    Application.put_env(:hydra_srt, :db_module, MissingTestDb)

    on_exit(fn ->
      Application.delete_env(:hydra_srt, :system_interfaces_module)
      Application.delete_env(:hydra_srt, :db_module)
    end)

    record = %{
      "schema" => "RTP",
      "host" => "239.1.1.2",
      "port" => 5004,
      "multicast" => true,
      "interface_sys_name" => "en0"
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["kind"] == "rtp"

    assert source["rtp"] == %{
             "address" => "239.1.1.2",
             "port" => 5004,
             "auto_multicast" => true,
             "multicast_iface" => "en0"
           }

    refute Map.has_key?(source["rtp"], "host")
    refute Map.has_key?(source["rtp"], "interface_sys_name")
  end

  test "source_from_record with invalid schema" do
    record = %{
      "schema" => "INVALID"
    }

    assert {:error, :invalid_source} = RouteHandler.source_from_record(record)
  end

  test "source_from_record with missing options" do
    record = %{"schema" => "SRT"}
    assert {:error, :invalid_source} = RouteHandler.source_from_record(record)
  end

  test "parse_native_json_line accepts structured pipeline log events" do
    line =
      Jason.encode!(%{
        "event" => "pipeline_log",
        "level" => "WARN",
        "category" => "native_config",
        "element" => "udpsrc",
        "message" => "ignored unsupported property host on udpsrc"
      })

    assert {:pipeline_log, log} = RouteHandler.parse_native_json_line(line)
    assert log["level"] == "WARN"
    assert log["category"] == "native_config"
    assert log["element"] == "udpsrc"
  end

  test "source_record_from_route picks active source id when present" do
    route = %{
      "active_source_id" => "s2",
      "sources" => [
        %{"id" => "s1", "position" => 0, "schema" => "UDP"},
        %{"id" => "s2", "position" => 1, "schema" => "SRT"}
      ]
    }

    assert {:ok, source} = RouteHandler.source_record_from_route(route, nil)
    assert source["id"] == "s2"
  end

  test "source_record_from_route falls back to position zero when active source missing" do
    route = %{
      "active_source_id" => "missing",
      "sources" => [
        %{"id" => "s1", "position" => 0, "schema" => "UDP"},
        %{"id" => "s2", "position" => 1, "schema" => "SRT"}
      ]
    }

    assert {:ok, source} = RouteHandler.source_record_from_route(route, nil)
    assert source["id"] == "s1"
  end

  test "source_record_from_route uses explicit source id argument" do
    route = %{
      "active_source_id" => "s1",
      "sources" => [
        %{"id" => "s1", "position" => 0, "schema" => "UDP"},
        %{"id" => "s2", "position" => 1, "schema" => "SRT"}
      ]
    }

    assert {:ok, source} = RouteHandler.source_record_from_route(route, "s2")
    assert source["id"] == "s2"
  end

  test "source_record_from_route returns invalid_source when explicit source id missing" do
    route = %{
      "active_source_id" => "s1",
      "sources" => [
        %{"id" => "s1", "position" => 0, "schema" => "UDP"}
      ]
    }

    assert {:error, :invalid_source} = RouteHandler.source_record_from_route(route, "s2")
  end

  test "next_enabled_source in active mode wraps around" do
    sources = [
      %{"id" => "p", "position" => 0, "enabled" => true},
      %{"id" => "b1", "position" => 1, "enabled" => true},
      %{"id" => "b2", "position" => 2, "enabled" => true}
    ]

    assert RouteHandler.next_enabled_source(sources, "p", "active")["id"] == "b1"
    assert RouteHandler.next_enabled_source(sources, "b1", "active")["id"] == "b2"
    assert RouteHandler.next_enabled_source(sources, "b2", "active")["id"] == "p"
  end

  test "next_enabled_source in passive mode wraps around" do
    sources = [
      %{"id" => "p", "position" => 0, "enabled" => true},
      %{"id" => "b1", "position" => 1, "enabled" => true}
    ]

    assert RouteHandler.next_enabled_source(sources, "p", "passive")["id"] == "b1"
    assert RouteHandler.next_enabled_source(sources, "b1", "passive")["id"] == "p"
  end

  test "next_enabled_source disabled mode always nil" do
    sources = [
      %{"id" => "p", "position" => 0, "enabled" => true},
      %{"id" => "b1", "position" => 1, "enabled" => true}
    ]

    assert RouteHandler.next_enabled_source(sources, "p", "disabled") == nil
  end

  test "next_enabled_source skips disabled entries" do
    sources = [
      %{"id" => "p", "position" => 0, "enabled" => true},
      %{"id" => "b1", "position" => 1, "enabled" => false},
      %{"id" => "b2", "position" => 2, "enabled" => true}
    ]

    assert RouteHandler.next_enabled_source(sources, "p", "passive")["id"] == "b2"
  end

  test "failover_target_source is nil when only one enabled source would wrap to itself" do
    sources = [
      %{"id" => "p", "position" => 0, "enabled" => true},
      %{"id" => "b1", "position" => 1, "enabled" => false}
    ]

    assert RouteHandler.failover_target_source(sources, "p", "passive") == nil
    assert RouteHandler.failover_target_source(sources, "p", "active") == nil
  end

  test "failover_target_source returns alternate source when backup is available" do
    sources = [
      %{"id" => "p", "position" => 0, "enabled" => true},
      %{"id" => "b1", "position" => 1, "enabled" => true}
    ]

    assert RouteHandler.failover_target_source(sources, "p", "passive")["id"] == "b1"
    assert RouteHandler.failover_target_source(sources, "b1", "passive")["id"] == "p"
    assert RouteHandler.failover_target_source(sources, "p", "active")["id"] == "b1"
  end

  test "failover_target_source is nil in disabled backup mode" do
    sources = [
      %{"id" => "p", "position" => 0, "enabled" => true},
      %{"id" => "b1", "position" => 1, "enabled" => true}
    ]

    assert RouteHandler.failover_target_source(sources, "p", "disabled") == nil
  end

  test "next_enabled_source returns current source when it is the only enabled source" do
    sources = [
      %{"id" => "p", "position" => 0, "enabled" => true},
      %{"id" => "b1", "position" => 1, "enabled" => false}
    ]

    assert RouteHandler.next_enabled_source(sources, "p", "active")["id"] == "p"
  end

  test "in_cooldown? boundary behavior" do
    refute RouteHandler.in_cooldown?(nil, 1000)
    refute RouteHandler.in_cooldown?(1000, 1000)
    refute RouteHandler.in_cooldown?(900, 1000)
    assert RouteHandler.in_cooldown?(1001, 1000)
  end

  test "should_trigger_source_loss_failover? uses single debounce window and cooldown" do
    data = %{
      route: %{"backup_mode" => "passive", "backup_switch_after_ms" => 3000},
      source_loss_elapsed_ms: 2500,
      cooldown_until: nil,
      now_ms: 1000
    }

    refute RouteHandler.should_trigger_source_loss_failover?(data)

    assert RouteHandler.should_trigger_source_loss_failover?(%{
             data
             | source_loss_elapsed_ms: 3000
           })

    refute RouteHandler.should_trigger_source_loss_failover?(%{
             data
             | source_loss_elapsed_ms: 3000,
               cooldown_until: 2000
           })
  end

  test "should_trigger_source_loss_failover? disabled mode blocks auto" do
    data = %{
      route: %{"backup_mode" => "disabled", "backup_switch_after_ms" => 1000},
      source_loss_elapsed_ms: 5000,
      now_ms: 1000
    }

    refute RouteHandler.should_trigger_source_loss_failover?(data)
  end

  test "observe_source_loss merges reconnecting and zero_bitrate into one window" do
    base = %{
      id: "route-soft-1",
      active_source_id: "s1",
      route: %{"backup_mode" => "passive", "backup_switch_after_ms" => 60_000},
      source_loss_since_ms: nil,
      source_loss_signal: nil,
      cooldown_until: nil,
      retry_scheduled?: false,
      retry_circuit_open?: false,
      recovery_blocked?: false
    }

    after_reconnect = RouteHandler.observe_source_loss(base, :reconnecting)
    assert is_integer(after_reconnect.source_loss_since_ms)
    assert after_reconnect.source_loss_signal == :reconnecting

    after_zero = RouteHandler.observe_source_loss(after_reconnect, :zero_bitrate)
    # Same soft budget — do not restart the debounce clock.
    assert after_zero.source_loss_since_ms == after_reconnect.source_loss_since_ms
    assert after_zero.source_loss_signal == :zero_bitrate
    refute after_zero[:retry_scheduled?]
  end

  test "observe_source_loss is suppressed when hard-retry already owns recovery" do
    data = %{
      id: "route-soft-2",
      active_source_id: "s1",
      route: %{"backup_mode" => "passive", "backup_switch_after_ms" => 1},
      source_loss_since_ms: nil,
      source_loss_signal: nil,
      cooldown_until: nil,
      retry_scheduled?: true,
      retry_circuit_open?: false,
      recovery_blocked?: false
    }

    next = RouteHandler.observe_source_loss(data, :zero_bitrate)
    assert next.source_loss_since_ms == nil
    assert next.retry_scheduled? == true
  end

  test "next_retry_backoff_ms stays within base..ceiling and grows with attempt" do
    base_ms = :timer.seconds(1)
    ceiling_ms = :timer.seconds(30)

    for attempt <- 1..6, _ <- 1..20 do
      delay = RouteHandler.next_retry_backoff_ms(nil, attempt)
      assert delay >= base_ms
      assert delay <= ceiling_ms
    end

    # Attempt 1 exp floor 1s → upper 3s; attempt 5 exp floor 16s → upper 30s.
    # Sample many draws; max observed for attempt 5 should exceed max for attempt 1.
    max_a1 =
      1..40
      |> Enum.map(fn _ -> RouteHandler.next_retry_backoff_ms(base_ms, 1) end)
      |> Enum.max()

    max_a5 =
      1..40
      |> Enum.map(fn _ -> RouteHandler.next_retry_backoff_ms(base_ms, 5) end)
      |> Enum.max()

    assert max_a1 <= :timer.seconds(3)
    assert max_a5 > max_a1
  end

  describe "retry circuit and terminal failure (stubbed runtime status)" do
    # These paths call HydraSrt.mark_route_failed/1; unit tests assert in-memory
    # recovery state only — stub the DB boundary like route_handler_failover_test.
    setup do
      :meck.new(HydraSrt.Db, [:passthrough])
      :meck.new(HydraSrt, [:passthrough])
      :meck.new(HydraSrt.Stats.EventLogger, [:passthrough])

      :meck.expect(HydraSrt, :mark_route_failed, fn _id -> {:ok, %{}} end)
      :meck.expect(HydraSrt, :mark_route_started, fn _id -> {:ok, %{}} end)
      :meck.expect(HydraSrt, :mark_route_stopped, fn _id -> {:ok, %{}} end)
      :meck.expect(HydraSrt, :mark_route_terminated, fn _id -> {:ok, %{}} end)
      :meck.expect(HydraSrt, :set_route_runtime_status, fn _id, _status -> {:ok, %{}} end)
      :meck.expect(HydraSrt.Db, :update_route_runtime_status, fn _id, _status -> {:ok, %{}} end)

      on_exit(fn -> :meck.unload() end)
      :ok
    end

    test "schedule_retry_restart opens circuit after max attempts and schedules nothing" do
      data =
        base_route_data(%{
          id: "route-circuit-1",
          active_source_id: "s1",
          retry_scheduled?: false,
          retry_attempt: 5,
          retry_prev_backoff_ms: :timer.seconds(30),
          retry_circuit_open?: false,
          recovery_blocked?: false
        })

      next = RouteHandler.schedule_retry_restart(data)

      assert next.retry_circuit_open? == true
      assert next.recovery_blocked? == true
      assert next.retry_scheduled? == false
      refute_receive :retry_start, 50
    end

    test "mark_terminal_failure blocks further retry scheduling" do
      data =
        base_route_data(%{
          id: "route-term-fail-1",
          active_source_id: "s1",
          retry_scheduled?: false,
          retry_attempt: 0,
          retry_prev_backoff_ms: nil,
          retry_circuit_open?: false,
          recovery_blocked?: false,
          source_loss_since_ms: 100,
          source_loss_signal: :reconnecting
        })

      next = RouteHandler.mark_terminal_failure(data, "NDI_DISABLED")

      assert next.recovery_blocked? == true
      assert next.retry_scheduled? == false
      assert next.source_loss_since_ms == nil

      assert RouteHandler.schedule_retry_restart(next) == next
      refute_receive :retry_start, 50
    end
  end

  test "schedule_retry_restart uses backoff and sets single retry timer" do
    data = %{
      id: "route-retry-1",
      active_source_id: "s1",
      retry_scheduled?: false,
      retry_attempt: 0,
      retry_prev_backoff_ms: nil,
      retry_circuit_open?: false,
      recovery_blocked?: false
    }

    next = RouteHandler.schedule_retry_restart(data)

    assert next.retry_scheduled? == true
    assert next.retry_attempt == 1
    assert is_integer(next.retry_prev_backoff_ms)
    assert next.retry_prev_backoff_ms >= :timer.seconds(1)
    assert next.retry_prev_backoff_ms <= :timer.seconds(30)

    # Second call while scheduled is a no-op (single-owner).
    assert RouteHandler.schedule_retry_restart(next) == next

    assert_receive :retry_start, next.retry_prev_backoff_ms + 100
  end

  test "policy_deny_reason? recognizes NDI_DISABLED" do
    assert RouteHandler.policy_deny_reason?("NDI_DISABLED")
    refute RouteHandler.policy_deny_reason?("other")
    refute RouteHandler.policy_deny_reason?(:enoent)
  end

  test "sink_from_record includes destination id and name for SRT" do
    record = %{
      "id" => "dest1",
      "name" => "Destination 1",
      "schema" => "SRT",
      "localaddress" => "127.0.0.1",
      "localport" => 4202,
      "mode" => "caller",
      "streamid" => "#!::r=destination"
    }

    assert {:ok, sink} = RouteHandler.sink_from_record(record)
    assert sink["id"] == "dest1"
    assert sink["name"] == "Destination 1"
    assert sink["kind"] == "srt"
    assert sink["srt"]["mode"] == "caller"
    assert sink["srt"]["streamid"] == "#!::r=destination"

    assert URI.decode_query(URI.parse(sink["srt"]["uri"]).query)["streamid"] ==
             "#!::r=destination"

    refute Map.has_key?(sink["srt"], "access")
  end

  test "sink_from_record does not send preserved streamid to a listener pipeline" do
    record = %{
      "id" => "dest-listener",
      "schema" => "SRT",
      "localaddress" => "127.0.0.1",
      "localport" => 4202,
      "mode" => "listener",
      "streamid" => "#!::r=preserved"
    }

    assert {:ok, sink} = RouteHandler.sink_from_record(record)
    refute Map.has_key?(sink["srt"], "streamid")
    refute URI.decode_query(URI.parse(sink["srt"]["uri"]).query) |> Map.has_key?("streamid")
  end

  test "sink_from_record includes destination id and name for UDP" do
    record = %{
      "id" => "dest2",
      "name" => "Destination 2",
      "schema" => "UDP",
      "host" => "127.0.0.1",
      "port" => 4203
    }

    assert {:ok, sink} = RouteHandler.sink_from_record(record)
    assert sink["id"] == "dest2"
    assert sink["name"] == "Destination 2"
    assert sink["kind"] == "udp"
    assert sink["udp"] == %{"address" => "127.0.0.1", "port" => 4203}
  end

  test "sink_from_record returns error for RTMP destination without location" do
    record = %{
      "id" => "dest-rtmp",
      "enabled" => true,
      "name" => "RTMP destination",
      "schema" => "RTMP"
    }

    assert {:error, :invalid_destination} = RouteHandler.sink_from_record(record)
  end

  test "sink_from_record includes destination id and name for RTMP" do
    record = %{
      "id" => "dest-rtmp",
      "enabled" => true,
      "name" => "RTMP destination",
      "schema" => "RTMP",
      "location" => "rtmp://127.0.0.1:1935/live/stream"
    }

    assert {:ok, sink} = RouteHandler.sink_from_record(record)

    assert sink == %{
             "id" => "dest-rtmp",
             "name" => "RTMP destination",
             "kind" => "rtmp",
             "rtmp" => %{"location" => "rtmp://127.0.0.1:1935/live/stream"}
           }
  end

  test "sink_from_record keeps udp bind and multicast interface properties" do
    record = %{
      "id" => "dest3",
      "name" => "Destination 3",
      "schema" => "UDP",
      "host" => "239.1.1.1",
      "port" => 5004,
      "bind_address_option" => "10.10.0.2",
      "multicast_iface" => "eno2"
    }

    assert {:ok, sink} = RouteHandler.sink_from_record(record)
    assert sink["kind"] == "udp"

    assert sink["udp"] == %{
             "address" => "239.1.1.1",
             "port" => 5004,
             "bind_address" => "10.10.0.2",
             "multicast_iface" => "eno2"
           }
  end

  test "sink_from_record drops bind-address for IPv6 multicast with link-local interface ip" do
    record = %{
      "id" => "dest4",
      "name" => "Destination 4",
      "schema" => "UDP",
      "host" => "ff15::1234",
      "port" => 5000,
      "bind_address_option" => "fe80::ae1f:6bff:febd:5295",
      "multicast_iface" => "eno2"
    }

    assert {:ok, sink} = RouteHandler.sink_from_record(record)

    assert sink == %{
             "id" => "dest4",
             "name" => "Destination 4",
             "kind" => "udp",
             "udp" => %{
               "address" => "ff15::1234",
               "port" => 5000,
               "multicast_iface" => "eno2"
             }
           }
  end

  test "sinks_from_record skips disabled destinations" do
    record = %{
      "destinations" => [
        %{
          "id" => "dest-enabled",
          "enabled" => true,
          "name" => "Enabled destination",
          "schema" => "UDP",
          "host" => "127.0.0.1",
          "port" => 4203
        },
        %{
          "id" => "dest-disabled",
          "enabled" => false,
          "name" => "Disabled destination",
          "schema" => "UDP",
          "host" => "127.0.0.1",
          "port" => 4204
        }
      ]
    }

    assert {:ok, [sink]} = RouteHandler.sinks_from_record(record)
    assert sink["id"] == "dest-enabled"
  end

  test "sinks_from_record includes only explicitly enabled destinations" do
    record = %{
      "destinations" => [
        %{
          "id" => "dest-enabled",
          "enabled" => true,
          "name" => "Enabled destination",
          "schema" => "UDP",
          "host" => "127.0.0.1",
          "port" => 4203
        },
        %{
          "id" => "dest-missing-enabled",
          "name" => "Missing enabled flag",
          "schema" => "UDP",
          "host" => "127.0.0.1",
          "port" => 4204
        },
        %{
          "id" => "dest-nil-enabled",
          "enabled" => nil,
          "name" => "Nil enabled flag",
          "schema" => "UDP",
          "host" => "127.0.0.1",
          "port" => 4205
        }
      ]
    }

    assert {:ok, [sink]} = RouteHandler.sinks_from_record(record)
    assert sink["id"] == "dest-enabled"
  end

  test "sinks_from_record preserves declared destination order" do
    record = %{
      "destinations" => [
        %{
          "id" => "dest-first",
          "enabled" => true,
          "schema" => "UDP",
          "host" => "127.0.0.1",
          "port" => 4203
        },
        %{
          "id" => "dest-second",
          "enabled" => true,
          "schema" => "UDP",
          "host" => "127.0.0.1",
          "port" => 4204
        }
      ]
    }

    assert {:ok, sinks} = RouteHandler.sinks_from_record(record)

    assert Enum.map(sinks, & &1["id"]) == [
             "dest-first",
             "dest-second"
           ]
  end

  test "build_config emits typed per-kind endpoints" do
    source_record = %{"id" => "source-1", "name" => "Source One", "schema" => "SRT"}

    source = %{
      "kind" => "srt",
      "srt" => %{
        "uri" => "srt://127.0.0.1:4201?mode=listener",
        "mode" => "listener",
        "latency" => 200,
        "localaddress" => "127.0.0.1",
        "localport" => 4201
      }
    }

    first_sink = %{
      "id" => "dest-first",
      "name" => "First",
      "kind" => "srt",
      "srt" => %{
        "uri" => "srt://127.0.0.1:4202?mode=caller",
        "mode" => "caller"
      }
    }

    second_sink = %{
      "id" => "dest-second",
      "name" => "Second",
      "kind" => "udp",
      "udp" => %{"address" => "127.0.0.1", "port" => 4203}
    }

    config =
      RouteHandler.build_config(
        "route-1",
        source_record,
        source,
        [first_sink, second_sink]
      )

    assert config["route_id"] == "route-1"
    refute Map.has_key?(config, "processing_profiles")
    assert "boot-" <> revision = config["config_revision"]
    assert {:ok, _} = Ecto.UUID.cast(revision)
    assert {:ok, _} = Ecto.UUID.cast(config["process_instance_id"])

    assert config["source"] == %{
             "id" => "source-1",
             "name" => "Source One",
             "kind" => "srt",
             "srt" => source["srt"]
           }

    refute Map.has_key?(config["source"], "legacy")
    refute Map.has_key?(config["source"], "element_type")

    assert Enum.map(config["destinations"], & &1["id"]) == ["dest-first", "dest-second"]

    assert config["destinations"] == [
             %{
               "id" => "dest-first",
               "name" => "First",
               "kind" => "srt",
               "srt" => first_sink["srt"]
             },
             %{
               "id" => "dest-second",
               "name" => "Second",
               "kind" => "udp",
               "udp" => second_sink["udp"]
             }
           ]
  end

  test "native_route_args emits the route CLI contract" do
    assert RouteHandler.native_route_args("route-1", "piid-1") == [
             "route",
             "--route-id",
             "route-1",
             "--process-instance-id",
             "piid-1"
           ]
  end

  test "build_config creates fresh spawn identities" do
    source_record = %{"id" => "source-1", "schema" => "UDP"}
    source = %{"kind" => "udp", "udp" => %{"address" => "127.0.0.1", "port" => 4201}}

    first = RouteHandler.build_config("route-1", source_record, source, [])
    second = RouteHandler.build_config("route-1", source_record, source, [])

    refute first["config_revision"] == second["config_revision"]
    refute first["process_instance_id"] == second["process_instance_id"]
  end

  test "callback_mode returns handle_event_function" do
    assert RouteHandler.callback_mode() == [:handle_event_function]
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

    assert {:update, "processing"} =
             RouteHandler.normalize_runtime_status("processing", nil, %{recovering?: true})
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

  describe "process_port_line pipeline logs" do
    @valid_gstreamer_line "0:00:00.123456789 1234 0x7f8b9c000b70 WARN srt src/srt.c:123:srt_connect:<srt-src> connection failed"

    setup do
      test_pid = self()
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "pipeline_logs")

      unparsed_handler = "route-handler-unparsed-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          unparsed_handler,
          HydraSrt.PipelineLogTelemetry.unparsed_event(),
          fn event, measurements, metadata, receiver ->
            send(receiver, {:telemetry_unparsed, event, measurements, metadata})
          end,
          test_pid
        )

      on_exit(fn -> :telemetry.detach(unparsed_handler) end)

      {:ok, data: %{id: "route-handler-pl-1", port_buffer: ""}}
    end

    test "broadcasts parsed GStreamer line on pipeline_logs pubsub", %{data: data} do
      RouteHandler.consume_port_output(@valid_gstreamer_line <> "\n", data)

      assert_receive {:pipeline_log, log}
      assert log.route_id == "route-handler-pl-1"
      assert log.level == "WARN"
      assert log.category == "srt"
      assert log.message == "connection failed"
    end

    test "emits unparsed telemetry for non-GStreamer lines", %{data: data} do
      RouteHandler.consume_port_output("not a gstreamer log line\n", data)

      refute_receive {:pipeline_log, _}, 50

      assert_receive {:telemetry_unparsed, _event, %{count: 1}, %{route_id: "route-handler-pl-1"}}
    end

    test "broadcasts native SRT access events on pipeline_logs pubsub", %{data: data} do
      RouteHandler.consume_port_output(
        ~s({"event":"srt_access","ip":"127.0.0.1","stream_id":"test","allowed":false,"reason":"denied_list"}) <>
          "\n",
        data
      )

      assert_receive {:pipeline_log, log}
      assert log.route_id == "route-handler-pl-1"
      assert log.level == "WARN"
      assert log.category == "srt_access"
      assert log.element == "srtsrc"
      assert log.message =~ "ip=127.0.0.1"
      assert log.message =~ "stream_id=test"
      assert log.message =~ "allowed=false"
      assert log.message =~ "reason=denied_list"
    end
  end

  describe "NDI source and destination mapping" do
    test "source_from_record maps discovery_name mode with W1 defaults" do
      route = %{"id" => "route-ndi", "name" => "Studio A"}

      record = %{
        "id" => "src-ndi",
        "schema" => "NDI",
        "ndi_selection_mode" => "discovery_name",
        "ndi_source_name" => "MACHINE (CHANNEL)"
      }

      assert {:ok, source} = RouteHandler.source_from_record(record, route)
      assert source["kind"] == "ndi"

      assert source["ndi"] == %{
               "source_name" => "MACHINE (CHANNEL)",
               "receiver_name" => "Hydra Studio A",
               "bandwidth" => "highest",
               "color_format" => "uyvy-bgra",
               "media_policy" => "video_and_audio_required",
               "connect_timeout_ms" => 10_000,
               "receive_timeout_ms" => 5_000,
               "track_discovery_timeout_ms" => 10_000,
               "max_queue_length" => 4
             }

      refute Map.has_key?(source["ndi"], "url_address")
      refute Map.has_key?(source["ndi"], "timestamp_mode")
    end

    test "source_from_record maps direct_address mode and preserves explicit options" do
      route = %{"id" => "route-ndi", "name" => "Studio B"}

      record = %{
        "id" => "src-ndi",
        "schema" => "NDI",
        "ndi_selection_mode" => "direct_address",
        "ndi_source_address" => "192.0.2.10:5960",
        "ndi_receiver_name" => "Custom Receiver",
        "ndi_bandwidth" => "audio_only",
        "ndi_color_format" => "best",
        "ndi_timestamp_mode" => "receive-time-vs-timestamp",
        "ndi_media_policy" => "audio_only",
        "ndi_connect_timeout_ms" => 2000,
        "ndi_receive_timeout_ms" => 3000,
        "ndi_track_discovery_timeout_ms" => 4000,
        "ndi_max_queue_length" => 8
      }

      assert {:ok, source} = RouteHandler.source_from_record(record, route)
      assert source["kind"] == "ndi"

      assert source["ndi"] == %{
               "url_address" => "192.0.2.10:5960",
               "receiver_name" => "Custom Receiver",
               "bandwidth" => "audio_only",
               "color_format" => "best",
               "timestamp_mode" => "receive-time-vs-timestamp",
               "media_policy" => "audio_only",
               "connect_timeout_ms" => 2000,
               "receive_timeout_ms" => 3000,
               "track_discovery_timeout_ms" => 4000,
               "max_queue_length" => 8
             }

      refute Map.has_key?(source["ndi"], "source_name")
    end

    test "sink_from_record maps NDI destination sender_name and media_policy default" do
      record = %{
        "id" => "dest-ndi",
        "name" => "NDI Out",
        "schema" => "NDI",
        "ndi_sender_name" => "Hydra (Route Output)"
      }

      assert {:ok, sink} = RouteHandler.sink_from_record(record)

      assert sink == %{
               "id" => "dest-ndi",
               "name" => "NDI Out",
               "kind" => "ndi",
               "ndi" => %{
                 "sender_name" => "Hydra (Route Output)",
                 "media_policy" => "video_and_audio_required"
               }
             }
    end

    test "build_config emits typed NDI source and destinations" do
      source_record = %{"id" => "src-ndi", "name" => "NDI In", "schema" => "NDI"}

      source = %{
        "kind" => "ndi",
        "ndi" => %{
          "source_name" => "MACHINE (CHANNEL)",
          "receiver_name" => "Hydra Studio A",
          "bandwidth" => "highest",
          "color_format" => "uyvy-bgra",
          "media_policy" => "video_and_audio_required",
          "connect_timeout_ms" => 10_000,
          "receive_timeout_ms" => 5_000,
          "track_discovery_timeout_ms" => 10_000,
          "max_queue_length" => 4
        }
      }

      sink = %{
        "id" => "dest-ndi",
        "name" => "NDI Out",
        "kind" => "ndi",
        "ndi" => %{
          "sender_name" => "Hydra (Route Output)",
          "media_policy" => "video_and_audio_required"
        }
      }

      config = RouteHandler.build_config("route-ndi", source_record, source, [sink])

      assert config["source"] == %{
               "id" => "src-ndi",
               "name" => "NDI In",
               "kind" => "ndi",
               "ndi" => source["ndi"]
             }

      assert config["destinations"] == [
               %{
                 "id" => "dest-ndi",
                 "name" => "NDI Out",
                 "kind" => "ndi",
                 "ndi" => sink["ndi"]
               }
             ]
    end
  end

  describe "NDI feature policy start gate" do
    setup do
      previous = Application.get_env(:hydra_srt, :ndi)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:hydra_srt, :ndi)
        else
          Application.put_env(:hydra_srt, :ndi, previous)
        end
      end)

      :ok
    end

    test "ensure_ndi_start_allowed denies NDI source when receive is disabled" do
      Application.put_env(:hydra_srt, :ndi, enabled: true, receive: false, send: true)

      route = %{
        "destinations" => [
          %{
            "id" => "dest-ndi",
            "enabled" => true,
            "schema" => "NDI",
            "ndi_sender_name" => "Out"
          }
        ]
      }

      source = %{"schema" => "NDI"}

      assert {:error, "NDI_DISABLED"} = RouteHandler.ensure_ndi_start_allowed(route, source)
    end

    test "ensure_ndi_start_allowed denies NDI destination when send is disabled" do
      Application.put_env(:hydra_srt, :ndi, enabled: true, receive: true, send: false)

      route = %{
        "destinations" => [
          %{
            "id" => "dest-ndi",
            "enabled" => true,
            "schema" => "NDI",
            "ndi_sender_name" => "Out"
          }
        ]
      }

      source = %{"schema" => "SRT"}

      assert {:error, "NDI_DISABLED"} = RouteHandler.ensure_ndi_start_allowed(route, source)
    end

    test "ensure_ndi_start_allowed allows non-NDI routes regardless of flags" do
      Application.put_env(:hydra_srt, :ndi, enabled: false, receive: false, send: false)

      route = %{
        "destinations" => [
          %{"id" => "dest-udp", "enabled" => true, "schema" => "UDP"}
        ]
      }

      source = %{"schema" => "SRT"}

      assert :ok = RouteHandler.ensure_ndi_start_allowed(route, source)
    end

    test "ensure_ndi_start_allowed allows NDI when enabled receive and send match" do
      Application.put_env(:hydra_srt, :ndi, enabled: true, receive: true, send: true)

      route = %{
        "destinations" => [
          %{
            "id" => "dest-ndi",
            "enabled" => true,
            "schema" => "NDI",
            "ndi_sender_name" => "Out"
          }
        ]
      }

      source = %{"schema" => "NDI"}

      assert :ok = RouteHandler.ensure_ndi_start_allowed(route, source)
    end
  end

  describe "strict destination validation" do
    test "sinks_from_record aggregates every failing enabled destination id" do
      record = %{
        "destinations" => [
          %{
            "id" => "dest-ok",
            "enabled" => true,
            "schema" => "UDP",
            "host" => "127.0.0.1",
            "port" => 4203
          },
          %{
            "id" => "dest-bad-rtmp",
            "enabled" => true,
            "schema" => "RTMP"
          },
          %{
            "id" => "dest-bad-ndi",
            "enabled" => true,
            "schema" => "NDI"
          },
          %{
            "id" => "dest-disabled-bad",
            "enabled" => false,
            "schema" => "RTMP"
          }
        ]
      }

      assert {:error, {:invalid_destinations, ["dest-bad-rtmp", "dest-bad-ndi"]}} =
               RouteHandler.sinks_from_record(record)
    end
  end

  describe "endpoint_health and route_terminal events" do
    test "parse_native_json_line recognizes endpoint_health and route_terminal" do
      health =
        Jason.encode!(%{
          "event" => "endpoint_health",
          "route_id" => "route-1",
          "process_instance_id" => "piid-1",
          "endpoint_id" => "ep-1",
          "state" => "connecting"
        })

      terminal =
        Jason.encode!(%{
          "event" => "route_terminal",
          "route_id" => "route-1",
          "process_instance_id" => "piid-1",
          "reason_code" => "NDI_RECEIVE_TIMEOUT",
          "retryable" => true,
          "retry_domain" => "route"
        })

      assert {:endpoint_health, %{"endpoint_id" => "ep-1"}} =
               RouteHandler.parse_native_json_line(health)

      assert {:route_terminal, %{"reason_code" => "NDI_RECEIVE_TIMEOUT", "retryable" => true}} =
               RouteHandler.parse_native_json_line(terminal)
    end

    test "consume_port_output stores matching endpoint_health and broadcasts on item topic" do
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "item:route-health-1")

      data = %{
        id: "route-health-1",
        process_instance_id: "piid-live",
        endpoint_health: %{},
        route_terminal: nil,
        port_buffer: ""
      }

      payload = %{
        "event" => "endpoint_health",
        "route_id" => "route-health-1",
        "process_instance_id" => "piid-live",
        "endpoint_id" => "ep-src",
        "state" => "streaming",
        "sequence" => 3
      }

      next = RouteHandler.consume_port_output(Jason.encode!(payload) <> "\n", data)

      assert next.endpoint_health["ep-src"]["state"] == "streaming"
      assert_receive {:endpoint_health, ^payload}
    end

    test "consume_port_output drops stale endpoint_health without broadcasting" do
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "item:route-health-2")

      data = %{
        id: "route-health-2",
        process_instance_id: "piid-live",
        endpoint_health: %{},
        route_terminal: nil,
        port_buffer: ""
      }

      payload = %{
        "event" => "endpoint_health",
        "route_id" => "route-health-2",
        "process_instance_id" => "piid-stale",
        "endpoint_id" => "ep-src",
        "state" => "failed"
      }

      next = RouteHandler.consume_port_output(Jason.encode!(payload) <> "\n", data)

      assert next.endpoint_health == %{}
      refute_receive {:endpoint_health, _}, 50
    end
  end

  describe "route_terminal recovery paths (stubbed runtime status)" do
    # mark_terminal_failure / mark_restarting_runtime touch HydraSrt + Db + EventLogger;
    # stub the full boundary exactly like route_handler_failover_test — assertions
    # are in-memory only.
    setup do
      :meck.new(HydraSrt.Db, [:passthrough])
      :meck.new(HydraSrt, [:passthrough])
      :meck.new(HydraSrt.Stats.EventLogger, [:passthrough])

      :meck.expect(HydraSrt, :mark_route_failed, fn _id -> {:ok, %{}} end)
      :meck.expect(HydraSrt, :mark_route_started, fn _id -> {:ok, %{}} end)
      :meck.expect(HydraSrt, :mark_route_stopped, fn _id -> {:ok, %{}} end)
      :meck.expect(HydraSrt, :mark_route_terminated, fn _id -> {:ok, %{}} end)
      :meck.expect(HydraSrt, :set_route_runtime_status, fn _id, _status -> {:ok, %{}} end)
      :meck.expect(HydraSrt.Db, :update_route_runtime_status, fn _id, _status -> {:ok, %{}} end)

      on_exit(fn -> :meck.unload() end)
      :ok
    end

    test "consume_port_output stores matching route_terminal for W3b without retrying" do
      data =
        base_route_data(%{
          id: "route-term-1",
          process_instance_id: "piid-live",
          active_source_id: "s1",
          source_loss_since_ms: 42,
          source_loss_signal: :reconnecting
        })

      payload = %{
        "event" => "route_terminal",
        "route_id" => "route-term-1",
        "process_instance_id" => "piid-live",
        "reason_code" => "NDI_SOURCE_EOS",
        "retryable" => false,
        "retry_domain" => "none",
        "detail" => "eos",
        "observed_at_ms" => 1,
        "sequence" => 9
      }

      next = RouteHandler.consume_port_output(Jason.encode!(payload) <> "\n", data)

      assert next.route_terminal == %{
               reason_code: "NDI_SOURCE_EOS",
               retryable: false,
               retry_domain: "none",
               detail: "eos",
               observed_at_ms: 1,
               sequence: 9
             }

      assert next.recovery_blocked? == true
      assert next.retry_scheduled? == false
      assert next.source_loss_since_ms == nil
      refute_receive :retry_start, 50
    end

    test "retryable route_terminal drives exactly one hard-retry timer" do
      data =
        base_route_data(%{
          id: "route-term-2",
          process_instance_id: "piid-live",
          active_source_id: "s1",
          route: %{"backup_mode" => "passive"},
          source_loss_since_ms: 99,
          source_loss_signal: :zero_bitrate
        })

      payload = %{
        "event" => "route_terminal",
        "route_id" => "route-term-2",
        "process_instance_id" => "piid-live",
        "reason_code" => "NDI_RECEIVE_TIMEOUT",
        "retryable" => true,
        "retry_domain" => "route",
        "detail" => "timeout",
        "observed_at_ms" => 2,
        "sequence" => 10
      }

      next = RouteHandler.consume_port_output(Jason.encode!(payload) <> "\n", data)

      assert next.route_terminal.reason_code == "NDI_RECEIVE_TIMEOUT"
      assert next.retry_scheduled? == true
      assert next.retry_attempt == 1
      assert next.source_loss_since_ms == nil
      assert next.recovery_blocked? == false

      # Soft path must not also arm while hard-retry owns recovery.
      soft = RouteHandler.observe_source_loss(next, :reconnecting)
      assert soft.source_loss_since_ms == nil
      assert soft.retry_scheduled? == true

      assert_receive :retry_start, next.retry_prev_backoff_ms + 100
    end

    test "single-owner: soft source-loss and hard-retry never double-fire" do
      data =
        base_route_data(%{
          id: "route-owner-1",
          active_source_id: "s1",
          route: %{"backup_mode" => "passive", "backup_switch_after_ms" => 1}
        })

      # Hard-retry arms first.
      hard = RouteHandler.schedule_retry_restart(data)
      assert hard.retry_scheduled? == true

      soft = RouteHandler.observe_source_loss(hard, :zero_bitrate)
      assert soft.source_loss_since_ms == nil
      assert soft.retry_scheduled? == true
      assert soft.retry_attempt == 1

      # Only one :retry_start message.
      assert_receive :retry_start, hard.retry_prev_backoff_ms + 100
      refute_receive :retry_start, 50
    end
  end

  describe "get_endpoint_health/1" do
    # Spawns a real RouteHandler (:gen_statem). Start failure → mark_restarting_runtime
    # and terminate → mark_route_stopped both reach HydraSrt → Db.*_with_previous → Repo.
    # Stub the Db write path the real HydraSrt helpers use (not only update_route_runtime_status/2),
    # same boundary pattern as route_handler_failover_test.
    setup do
      :meck.new(HydraSrt.Db, [:passthrough])
      :meck.new(HydraSrt, [:passthrough])
      :meck.new(HydraSrt.Stats.EventLogger, [:passthrough])

      stub_route = %{"id" => "stub-route", "status" => "stopped", "schema_status" => "stopped"}
      stub_prev = {:ok, %{route: stub_route, previous_status: nil}}

      :meck.expect(HydraSrt, :mark_route_failed, fn _id -> {:ok, stub_route} end)
      :meck.expect(HydraSrt, :mark_route_started, fn _id -> {:ok, stub_route} end)
      :meck.expect(HydraSrt, :mark_route_stopped, fn _id -> {:ok, stub_route} end)
      :meck.expect(HydraSrt, :mark_route_terminated, fn _id -> {:ok, stub_route} end)
      :meck.expect(HydraSrt, :set_route_runtime_status, fn _id, _status -> {:ok, stub_route} end)

      :meck.expect(HydraSrt.Db, :update_route_runtime_status, fn _id, _status ->
        {:ok, stub_route}
      end)

      :meck.expect(HydraSrt.Db, :update_route_runtime_status_with_previous, fn _id, _status ->
        stub_prev
      end)

      :meck.expect(
        HydraSrt.Db,
        :transition_route_runtime_status_with_previous,
        fn _id, _attrs, _dest_status, _src_status -> stub_prev end
      )

      :meck.expect(HydraSrt.Db, :update_route_status_with_previous, fn _id, _attrs ->
        stub_prev
      end)

      :meck.expect(HydraSrt.Db, :set_route_active_source, fn _id, _source_id, _reason ->
        {:ok, stub_route}
      end)

      :meck.expect(HydraSrt.Stats.EventLogger, :log_pipeline_failed, fn _, _, _, _ -> :ok end)
      :meck.expect(HydraSrt.Stats.EventLogger, :log_route_status_change, fn _, _, _ -> :ok end)

      on_exit(fn -> :meck.unload() end)
      :ok
    end

    test "call returns stored endpoint_health map and process identity" do
      route_id = "route-health-call-#{System.unique_integer([:positive])}"

      empty_route = %{
        "id" => route_id,
        "active_source_id" => nil,
        "sources" => [],
        "destinations" => []
      }

      :meck.expect(HydraSrt.Db, :get_route, fn
        ^route_id, true -> {:ok, empty_route}
        _id, _include_dest -> {:error, :not_found}
      end)

      {:ok, pid} = RouteHandler.start_link(%{id: route_id})

      on_exit(fn ->
        if Process.alive?(pid), do: :gen_statem.stop(pid, :normal, 1000)
      end)

      :sys.replace_state(pid, fn {state, data} ->
        {state,
         %{
           data
           | process_instance_id: "piid-call",
             endpoint_health: %{
               "ep-1" => %{
                 "endpoint_id" => "ep-1",
                 "state" => "streaming",
                 "sequence" => 4,
                 "config_revision" => "rev-call"
               }
             }
         }}
      end)

      assert {:ok, identity} = RouteHandler.get_endpoint_health(pid)
      assert identity.process_instance_id == "piid-call"
      assert identity.config_revision == "rev-call"
      assert identity.last_sequence == 4
      assert identity.endpoint_health["ep-1"]["state"] == "streaming"

      :gen_statem.stop(pid, :normal, 1000)
    end
  end
end

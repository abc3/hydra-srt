defmodule HydraSrt.SourceProbeTest do
  use ExUnit.Case, async: true

  alias HydraSrt.SourceProbe

  test "build_probe_uri/1 builds SRT probe URI from route config" do
    route = %{
      "schema" => "SRT",
      "localaddress" => "127.0.0.1",
      "localport" => 4201,
      "mode" => "listener"
    }

    assert {:ok, uri} = SourceProbe.build_probe_uri(route)
    assert uri == "srt://127.0.0.1:4201?mode=listener"
  end

  test "build_probe_uri/1 uses remote address and port in SRT caller mode" do
    route = %{
      "schema" => "SRT",
      "mode" => "caller",
      "address" => "203.0.113.8",
      "port" => 5001,
      "localaddress" => "10.0.0.12",
      "localport" => 4201
    }

    assert {:ok, uri} = SourceProbe.build_probe_uri(route)
    assert uri == "srt://203.0.113.8:5001?mode=caller"
  end

  test "build_probe_uri/1 builds UDP probe URI with default bind address" do
    route = %{
      "schema" => "UDP",
      "port" => 5000
    }

    assert {:ok, uri} = SourceProbe.build_probe_uri(route)
    assert uri == "udp://0.0.0.0:5000"
  end

  test "build_probe_uri/1 builds RTP probe URI for RTP source" do
    route = %{
      "schema" => "RTP",
      "address" => "127.0.0.1",
      "port" => 5004
    }

    assert {:ok, uri} = SourceProbe.build_probe_uri(route)
    assert uri == "rtp://127.0.0.1:5004"
  end

  test "build_probe_uri/1 returns an error when UDP port is missing" do
    route = %{
      "schema" => "UDP",
      "mode" => nil
    }

    assert {:error, "UDP source is missing a valid port"} = SourceProbe.build_probe_uri(route)
  end

  test "build_probe_uri/1 returns an error when SRT port is missing" do
    route = %{
      "schema" => "SRT",
      "localaddress" => "127.0.0.1",
      "mode" => "listener"
    }

    assert {:error, "SRT source is missing a valid port"} = SourceProbe.build_probe_uri(route)
  end

  test "build_probe_uri/1 returns an error when SRT port is invalid" do
    route = %{
      "schema" => "SRT",
      "localaddress" => "127.0.0.1",
      "localport" => 0,
      "mode" => "listener"
    }

    assert {:error, "SRT source has an invalid port"} = SourceProbe.build_probe_uri(route)
  end

  test "probe/1 rejects non-map input" do
    assert {:error, :invalid_source} = SourceProbe.probe(nil)
  end

  test "decode_output/1 accepts clean json" do
    output = ~s({"streams":[],"format":{"format_name":"mpegts"}})

    assert {:ok, decoded} = SourceProbe.decode_output(output)
    assert decoded["format"]["format_name"] == "mpegts"
  end

  test "decode_output/1 strips plain-text prefix before json" do
    output = """
    warning line
    {"streams":[],"format":{"format_name":"mpegts"}}
    """

    assert {:ok, decoded} = SourceProbe.decode_output(output)
    assert decoded["format"]["format_name"] == "mpegts"
  end

  test "decode_output/1 ignores braces in prefix and decodes trailing json" do
    output = """
    Connection refused {errno: 111}
    {"streams":[],"format":{"format_name":"mpegts"}}
    """

    assert {:ok, decoded} = SourceProbe.decode_output(output)
    assert decoded["format"]["format_name"] == "mpegts"
  end

  test "decode_output/1 returns error when json payload is missing" do
    assert {:error, "ffprobe returned invalid JSON"} = SourceProbe.decode_output("no json here")
  end

  test "normalize_programs/1 returns the fixed shape for a multi-program payload" do
    programs = [
      %{
        "program_num" => 11,
        "pmt_pid" => 4096,
        "pcr_pid" => 256,
        "tags" => %{"service_name" => "News"},
        "streams" => [
          %{"codec_type" => "video", "codec_name" => "h264", "index" => 0},
          %{"codec_type" => "audio", "codec_name" => "aac", "index" => 1}
        ]
      },
      %{
        "program_num" => 12,
        "pmt_pid" => 4097,
        "pcr_pid" => 258,
        "tags" => %{},
        "streams" => [%{"codec_type" => "video", "codec_name" => "h264"}]
      }
    ]

    assert SourceProbe.normalize_programs(programs) == [
             %{
               "program_number" => 11,
               "pmt_pid" => 4096,
               "pcr_pid" => 256,
               "name" => "News",
               "streams" => [
                 %{"codec_type" => "video", "codec_name" => "h264"},
                 %{"codec_type" => "audio", "codec_name" => "aac"}
               ]
             },
             %{
               "program_number" => 12,
               "pmt_pid" => 4097,
               "pcr_pid" => 258,
               "name" => nil,
               "streams" => [%{"codec_type" => "video", "codec_name" => "h264"}]
             }
           ]
  end

  test "normalize_programs/1 returns one entry for an SPTS payload" do
    assert [program] =
             SourceProbe.normalize_programs([
               %{
                 "program_num" => 12,
                 "pmt_pid" => 4097,
                 "pcr_pid" => 258,
                 "streams" => []
               }
             ])

    assert program == %{
             "program_number" => 12,
             "pmt_pid" => 4097,
             "pcr_pid" => 258,
             "name" => nil,
             "streams" => []
           }
  end

  test "normalize_programs/1 drops entries an operator could never select" do
    programs = [
      %{"program_num" => 0, "pmt_pid" => 0, "pcr_pid" => 0, "streams" => []},
      %{
        "program_num" => 12,
        "pmt_pid" => 4097,
        "pcr_pid" => 258,
        "tags" => %{"service_name" => "Service02"},
        "streams" => [%{"codec_type" => "video", "codec_name" => "h264"}]
      }
    ]

    assert [%{"program_number" => 12}] = SourceProbe.normalize_programs(programs)
  end

  test "normalize_programs/1 drops a program whose number is missing" do
    assert SourceProbe.normalize_programs([
             %{"pmt_pid" => 4096, "pcr_pid" => 256, "streams" => []}
           ]) == []
  end

  test "normalize_programs/1 returns an empty list when ffprobe reports no programs" do
    assert SourceProbe.normalize_programs([]) == []
    assert SourceProbe.normalize_programs(nil) == []
  end

  test "listener sources are told a sender must be connected" do
    assert SourceProbe.listener_timeout_hint(true) =~ "sender is connected"
    assert SourceProbe.listener_timeout_hint(false) == ""
  end

  test "listener_source?/1 recognizes the stored mode" do
    assert SourceProbe.listener_source?(%{"mode" => "listener"})
    assert SourceProbe.listener_source?(%{"mode" => "Listener"})
    refute SourceProbe.listener_source?(%{"mode" => "caller"})
    refute SourceProbe.listener_source?(%{})
  end

  test "an idle listener source times out with an actionable message" do
    source = %{
      "schema" => "SRT",
      "mode" => "listener",
      "localaddress" => "127.0.0.1",
      "localport" => 24_000 + :erlang.unique_integer([:positive, :monotonic]),
      "enabled" => true
    }

    assert {:error, message} = SourceProbe.probe(source, timeout_ms: 300)

    # The unit CI job has no ffmpeg, so assert the hint only where ffprobe can
    # actually run, and assert the missing-binary path otherwise.
    if System.find_executable("ffprobe") do
      assert message =~ "timed out"
      assert message =~ "sender is connected"
    else
      assert message == "ffprobe is not available on the server"
    end
  end

  test "a timed out probe leaves no ffprobe process behind" do
    if System.find_executable("ffprobe") do
      port = 24_500 + :erlang.unique_integer([:positive, :monotonic])

      source = %{
        "schema" => "SRT",
        "mode" => "listener",
        "localaddress" => "127.0.0.1",
        "localport" => port,
        "enabled" => true
      }

      assert {:error, _message} = SourceProbe.probe(source, timeout_ms: 300)

      # The killed child must release the port, otherwise the next test of the
      # same source fails with an address already in use error.
      assert wait_until_port_is_free(port, 40)
    end
  end

  test "collect_ffprobe_output returns the child output on a clean exit" do
    port = spawn_probe_port(["-c", ~s(printf '{"streams":[]}')])

    assert {:ok, output} = SourceProbe.collect_ffprobe_output(port, "", far_deadline(), context())
    assert output =~ ~s("streams")
  end

  test "collect_ffprobe_output surfaces the child diagnostic on a failing exit" do
    port = spawn_probe_port(["-c", "printf 'Connection refused\n{\n\n}\n'; exit 3"])

    assert {:error, message} =
             SourceProbe.collect_ffprobe_output(port, "", far_deadline(), context())

    assert message =~ "Connection refused"
    # The json skeleton must never become the message the operator sees.
    refute message =~ "{"
  end

  test "a failing child with no diagnostic falls back to its exit status" do
    port = spawn_probe_port(["-c", "printf '{\n\n}\n'; exit 4"])

    assert {:error, message} =
             SourceProbe.collect_ffprobe_output(port, "", far_deadline(), context())

    assert message == "ffprobe failed with exit status 4"
  end

  test "a timed out probe kills the child process it spawned" do
    port = spawn_probe_port(["-c", "sleep 30"])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    deadline = System.monotonic_time(:millisecond) + 50

    assert {:error, message} =
             SourceProbe.collect_ffprobe_output(port, "", deadline, context(listener?: true))

    assert message =~ "timed out after 300ms"
    assert message =~ "sender is connected"
    assert wait_until_process_is_gone(os_pid, 60), "the spawned child outlived its probe"
  end

  test "close_port tolerates a port that is already closed" do
    port = spawn_probe_port(["-c", "exit 0"])

    assert :ok = SourceProbe.close_port(port)
    assert :ok = SourceProbe.close_port(port)
  end

  test "client_error trims and truncates probe failures" do
    assert SourceProbe.client_error("  timeout  ") == "timeout"
    assert SourceProbe.client_error("") == "Failed to test source connection"
    assert String.length(SourceProbe.client_error(String.duplicate("x", 600))) == 500
  end

  @spec wait_until_port_is_free(pos_integer(), non_neg_integer()) :: boolean()
  def wait_until_port_is_free(_port, 0), do: false

  def wait_until_port_is_free(port, attempts) do
    case :gen_udp.open(port, [{:ip, {127, 0, 0, 1}}]) do
      {:ok, socket} ->
        :gen_udp.close(socket)
        true

      {:error, _reason} ->
        Process.sleep(50)
        wait_until_port_is_free(port, attempts - 1)
    end
  end

  @spec context(keyword()) :: map()
  def context(opts \\ []) do
    %{
      timeout_ms: 300,
      sanitized_uri: "srt://127.0.0.1:1234",
      listener_source?: Keyword.get(opts, :listener?, false)
    }
  end

  @spec far_deadline() :: integer()
  def far_deadline, do: System.monotonic_time(:millisecond) + 5_000

  # /bin/sh stands in for ffprobe so these paths are covered on CI runners that
  # have no ffmpeg installed.
  @spec spawn_probe_port([String.t()]) :: port()
  def spawn_probe_port(args) do
    Port.open({:spawn_executable, "/bin/sh"}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:args, args}
    ])
  end

  @spec wait_until_process_is_gone(pos_integer(), non_neg_integer()) :: boolean()
  def wait_until_process_is_gone(_os_pid, 0), do: false

  def wait_until_process_is_gone(os_pid, attempts) do
    # A reaped child disappears; a not yet reaped one reports the zombie state.
    {output, _status} =
      System.cmd("ps", ["-o", "state=", "-p", Integer.to_string(os_pid)], stderr_to_stdout: true)

    case String.trim(output) do
      "" ->
        true

      "Z" <> _rest ->
        true

      _running ->
        Process.sleep(50)
        wait_until_process_is_gone(os_pid, attempts - 1)
    end
  end
end

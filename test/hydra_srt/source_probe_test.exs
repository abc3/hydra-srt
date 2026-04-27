defmodule HydraSrt.SourceProbeTest do
  use ExUnit.Case, async: true

  alias HydraSrt.SourceProbe

  test "build_probe_uri/1 builds SRT probe URI from route config" do
    route = %{
      "schema" => "SRT",
      "schema_options" => %{
        "localaddress" => "127.0.0.1",
        "localport" => 4201,
        "mode" => "listener"
      }
    }

    assert {:ok, uri} = SourceProbe.build_probe_uri(route)
    assert uri == "srt://127.0.0.1:4201?mode=listener"
  end

  test "build_probe_uri/1 uses remote address and port in SRT caller mode" do
    route = %{
      "schema" => "SRT",
      "schema_options" => %{
        "mode" => "caller",
        "address" => "203.0.113.8",
        "port" => 5001,
        "localaddress" => "10.0.0.12",
        "localport" => 4201
      }
    }

    assert {:ok, uri} = SourceProbe.build_probe_uri(route)
    assert uri == "srt://203.0.113.8:5001?mode=caller"
  end

  test "build_probe_uri/1 builds UDP probe URI with default bind address" do
    route = %{
      "schema" => "UDP",
      "schema_options" => %{
        "port" => 5000
      }
    }

    assert {:ok, uri} = SourceProbe.build_probe_uri(route)
    assert uri == "udp://0.0.0.0:5000"
  end

  test "build_probe_uri/1 returns an error when UDP port is missing" do
    route = %{
      "schema" => "UDP",
      "schema_options" => %{}
    }

    assert {:error, "UDP source is missing a valid port"} = SourceProbe.build_probe_uri(route)
  end

  test "build_probe_uri/1 returns an error when SRT port is missing" do
    route = %{
      "schema" => "SRT",
      "schema_options" => %{
        "localaddress" => "127.0.0.1",
        "mode" => "listener"
      }
    }

    assert {:error, "SRT source is missing a valid port"} = SourceProbe.build_probe_uri(route)
  end

  test "build_probe_uri/1 returns an error when SRT port is invalid" do
    route = %{
      "schema" => "SRT",
      "schema_options" => %{
        "localaddress" => "127.0.0.1",
        "localport" => 0,
        "mode" => "listener"
      }
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
end

defmodule HydraSrt.E2E.Native.ProductionConfigContractTest do
  @moduledoc """
  Locks the Elixir↔Rust route-config contract against the REAL native parser.

  Everything here goes through `RouteHandler.route_data_to_params/1` — the same
  builder production uses — and hands the result to the native `validate-config`
  dry run, so a config the pipeline would reject (or abort on) fails here instead
  of in a media E2E run.
  """

  use HydraSrt.DataCase

  import HydraSrt.DbFixtures

  alias HydraSrt.E2E.Native.Helpers
  alias HydraSrt.RouteHandler

  @moduletag :native_e2e

  # NDI element factories ship with gst-plugin-ndi, which only the NDI E2E job
  # installs; missing plugins are an environment fact, not a contract break.
  @ndi_environment_reason_codes ~w(NDI_PLUGIN_MISSING NDI_PLUGIN_INCOMPATIBLE NDI_RUNTIME_MISSING)

  setup do
    Helpers.ensure_rs_native_binary_present!()
    :ok
  end

  test "SRT listener source and an unnamed SRT caller destination" do
    route = route_fixture()

    source_fixture(route, %{
      "schema" => "SRT",
      "mode" => "listener",
      "localaddress" => "127.0.0.1"
    })

    # No "name": the endpoints table leaves it NULL, and the wire contract needs
    # a string there.
    destination_fixture(route, %{
      "schema" => "SRT",
      "mode" => "caller",
      "localaddress" => "127.0.0.1",
      "streamid" => "#!::r=destination",
      "name" => nil
    })

    config = build_config!(route)

    assert_native_accepts!(config)
    assert config["destinations"] |> hd() |> Map.fetch!("name") |> is_binary()
  end

  test "encrypted SRT listener source" do
    route = route_fixture()

    source_fixture(route, %{
      "schema" => "SRT",
      "mode" => "listener",
      "localaddress" => "127.0.0.1",
      "passphrase" => "0123456789abcdef",
      "pbkeylen" => 16
    })

    destination_fixture(route, %{"schema" => "UDP", "host" => "127.0.0.1"})

    config = build_config!(route)

    assert %{"passphrase" => "0123456789abcdef", "pbkeylen" => 16} = srt_source(config)
    assert_native_accepts!(config)
  end

  test "SRT caller source keeps the peer in the URI and off the SRT payload" do
    route = route_fixture()

    source_fixture(route, %{
      "schema" => "SRT",
      "mode" => "caller",
      "address" => "127.0.0.1",
      "port" => 9100
    })

    destination_fixture(route, %{"schema" => "UDP", "host" => "127.0.0.1"})

    config = build_config!(route)
    srt = srt_source(config)

    assert srt["uri"] =~ "srt://127.0.0.1:9100"
    refute Map.has_key?(srt, "address")
    refute Map.has_key?(srt, "port")
    assert_native_accepts!(config)
  end

  test "SRT listener destination" do
    route = route_fixture()
    source_fixture(route, %{"schema" => "UDP", "host" => "127.0.0.1"})

    destination_fixture(route, %{
      "schema" => "SRT",
      "mode" => "listener",
      "localaddress" => "127.0.0.1"
    })

    assert_native_accepts!(build_config!(route))
  end

  test "UDP source and UDP destination" do
    route = route_fixture()
    source_fixture(route, %{"schema" => "UDP", "host" => "127.0.0.1"})
    destination_fixture(route, %{"schema" => "UDP", "host" => "127.0.0.1"})

    assert_native_accepts!(build_config!(route))
  end

  test "UDP multicast source" do
    route = route_fixture()

    source_fixture(route, %{
      "schema" => "UDP",
      "host" => "239.1.1.1",
      "multicast" => true,
      "multicast_iface" => "lo"
    })

    destination_fixture(route, %{"schema" => "UDP", "host" => "127.0.0.1"})

    config = build_config!(route)

    assert %{"auto_multicast" => true, "multicast_iface" => "lo"} =
             config["source"]["udp"]

    assert_native_accepts!(config)
  end

  test "RTP source and SRT destination" do
    route = route_fixture()
    source_fixture(route, %{"schema" => "RTP", "host" => "127.0.0.1"})

    destination_fixture(route, %{
      "schema" => "SRT",
      "mode" => "caller",
      "localaddress" => "127.0.0.1"
    })

    assert_native_accepts!(build_config!(route))
  end

  test "RTMP source and UDP destination" do
    route = route_fixture()
    source_fixture(route, %{"schema" => "RTMP", "path" => "/live/contract"})
    destination_fixture(route, %{"schema" => "UDP", "host" => "127.0.0.1"})

    assert_native_accepts!(build_config!(route))
  end

  test "SRT source and RTMP destination" do
    route = route_fixture()

    source_fixture(route, %{
      "schema" => "SRT",
      "mode" => "listener",
      "localaddress" => "127.0.0.1"
    })

    destination_fixture(route, %{
      "schema" => "RTMP",
      "location" => "rtmp://127.0.0.1:1935/live/contract"
    })

    assert_native_accepts!(build_config!(route))
  end

  test "SRT bind selection maps onto localaddress" do
    route = route_fixture()

    source_fixture(route, %{
      "schema" => "SRT",
      "mode" => "caller",
      "address" => "127.0.0.1",
      "port" => 9100,
      "bind_address_option" => "127.0.0.1"
    })

    destination_fixture(route, %{"schema" => "UDP", "host" => "127.0.0.1"})

    config = build_config!(route)
    srt = srt_source(config)

    assert srt["localaddress"] == "127.0.0.1"
    refute Map.has_key?(srt, "bind_address")
    refute Map.has_key?(srt, "multicast_iface")
    assert_native_accepts!(config)
  end

  test "interface selection on an SRT source" do
    route = route_fixture()

    source_fixture(route, %{
      "schema" => "SRT",
      "mode" => "listener",
      "localaddress" => "127.0.0.1",
      "interface_sys_name" => "lo"
    })

    destination_fixture(route, %{"schema" => "UDP", "host" => "127.0.0.1"})

    config = build_config!(route)
    srt = srt_source(config)

    refute Map.has_key?(srt, "bind_address")
    refute Map.has_key?(srt, "multicast_iface")
    assert_native_accepts!(config)
  end

  test "NDI source and NDI destination" do
    previous = Application.get_env(:hydra_srt, :ndi, [])
    Application.put_env(:hydra_srt, :ndi, enabled: true, receive: true, send: true)
    on_exit(fn -> Application.put_env(:hydra_srt, :ndi, previous) end)

    route = route_fixture()

    source_fixture(route, %{
      "schema" => "NDI",
      "ndi_selection_mode" => "discovery_name",
      "ndi_source_name" => "HYDRA (Contract)",
      "ndi_media_policy" => "video_only"
    })

    destination_fixture(route, %{
      "schema" => "NDI",
      "ndi_sender_name" => "Hydra Contract Out",
      "ndi_media_policy" => "video_only"
    })

    config = build_config!(route)

    case Helpers.validate_native_config(config) do
      {0, %{"event" => "config_valid"}} ->
        :ok

      {status, %{"event" => "config_rejected", "reason_code" => code} = result} ->
        assert status != 101, "native binary aborted on an NDI config: #{inspect(result)}"

        assert code in @ndi_environment_reason_codes,
               "native binary rejected the production NDI config: #{inspect(result)}"

      other ->
        flunk("unexpected validate-config outcome: #{inspect(other)}")
    end
  end

  defp build_config!(route) do
    assert {:ok, config} = RouteHandler.route_data_to_params(route["id"])
    config
  end

  defp srt_source(config), do: config["source"]["srt"]

  defp assert_native_accepts!(config) do
    assert {0, %{"event" => "config_valid"}} = Helpers.validate_native_config(config)
  end
end

defmodule HydraSrt.Ndi.CapabilitiesTest do
  use ExUnit.Case, async: false

  alias HydraSrt.Ndi.Capabilities

  setup do
    previous = Application.get_env(:hydra_srt, :ndi, :__unset__)

    on_exit(fn ->
      case previous do
        :__unset__ -> Application.delete_env(:hydra_srt, :ndi)
        value -> Application.put_env(:hydra_srt, :ndi, value)
      end
    end)

    :ok
  end

  test "disabled feature reports NDI_DISABLED without top-level available" do
    Application.put_env(:hydra_srt, :ndi, enabled: false, receive: false, send: false)

    snapshot = %{
      devices: [],
      stale: false,
      capability: %{ok: false, reason_code: "NDI_DISABLED"},
      truncated: false
    }

    caps = Capabilities.compose(snapshot, ~U[2026-07-18 00:00:00Z])

    refute Map.has_key?(caps, :available)
    assert caps.feature_enabled == false
    assert caps.receive.available == false
    assert caps.receive.reason_codes == ["NDI_DISABLED"]
    assert caps.send.reason_codes == ["NDI_DISABLED"]
    assert caps.discovery.reason_codes == ["NDI_DISABLED"]
    assert caps.discovery.mode == "mdns"
    assert caps.plugin.available == false
    assert caps.runtime.available == false
    assert caps.checked_at == "2026-07-18T00:00:00Z"
    assert caps.expires_at == "2026-07-18T00:00:15Z"
    assert caps.stale == false
    assert caps.check_in_progress == false
  end

  test "plugin missing marks receive/send/discovery unavailable" do
    Application.put_env(:hydra_srt, :ndi, enabled: true, receive: true, send: true)

    snapshot = %{
      devices: [],
      stale: false,
      capability: %{ok: false, reason_code: "NDI_PLUGIN_MISSING"},
      truncated: false
    }

    caps = Capabilities.compose(snapshot)

    assert caps.feature_enabled == true
    assert caps.plugin.available == false
    assert caps.runtime.available == false
    assert caps.receive.available == false
    assert caps.receive.reason_codes == ["NDI_PLUGIN_MISSING"]
    assert caps.send.reason_codes == ["NDI_PLUGIN_MISSING"]
    assert caps.discovery.reason_codes == ["NDI_PLUGIN_MISSING"]
    assert caps.direct_address.reason_codes == ["NDI_PLUGIN_MISSING"]
  end

  test "available helper with receive/send flags reports formats" do
    Application.put_env(:hydra_srt, :ndi, enabled: true, receive: true, send: true)

    snapshot = %{
      devices: [],
      stale: false,
      capability: %{ok: true, reason_code: nil},
      truncated: false
    }

    caps = Capabilities.compose(snapshot)

    assert caps.plugin.available == true
    assert caps.runtime.available == true
    assert caps.receive.available == true
    assert caps.receive.formats != []
    assert caps.send.available == true
    assert caps.discovery.available == true
    assert caps.direct_address.available == true
    assert caps.receive.reason_codes == []
  end

  test "Avahi failure disables discovery but can keep direct_address" do
    Application.put_env(:hydra_srt, :ndi, enabled: true, receive: true, send: false)

    snapshot = %{
      devices: [],
      stale: false,
      capability: %{ok: false, reason_code: "NDI_AVAHI_UNAVAILABLE"},
      truncated: false
    }

    caps = Capabilities.compose(snapshot)

    assert caps.discovery.available == false
    assert caps.discovery.reason_codes == ["NDI_AVAHI_UNAVAILABLE"]
    assert caps.direct_address.available == true
    assert caps.receive.available == true
    assert caps.receive.reason_codes == []
    assert caps.send.available == false
    assert caps.send.reason_codes == ["NDI_DISABLED"]
  end

  test "list_sources denies when feature disabled and never requires spawn" do
    Application.put_env(:hydra_srt, :ndi, enabled: false)

    assert {:error, "NDI_DISABLED", _} =
             Capabilities.list_sources(
               principal: "p1",
               snapshot_fun: fn -> flunk("should not snapshot") end
             )
  end

  test "list_sources issues tokens bound to principal and groups duplicates" do
    Application.put_env(:hydra_srt, :ndi, enabled: true, receive: true, send: false)

    snapshot = %{
      devices: [
        %{
          "display_name" => "CAM A",
          "properties" => "url-address=(string)192.0.2.10:5961"
        },
        %{
          "display_name" => "CAM A",
          "properties" => "url-address=(string)192.0.2.11:5961"
        },
        %{
          "display_name" => "CAM B",
          "properties" => "url-address=(string)192.0.2.12:5961"
        }
      ],
      stale: false,
      capability: %{ok: true, reason_code: nil},
      truncated: false
    }

    assert {:ok, %{data: data, meta: meta}} =
             Capabilities.list_sources(
               principal: "principal-a",
               snapshot_fun: fn -> snapshot end,
               now: ~U[2026-07-18 00:00:00Z]
             )

    assert length(data) == 3
    assert meta.result_count == 3
    assert meta.generation

    assert [%{name: "CAM A", count: 2, reason_code: "NDI_SOURCE_NAME_AMBIGUOUS"}] =
             meta.duplicate_name_groups

    token = hd(data).selection_token

    assert {:ok, payload} =
             Capabilities.resolve_selection_token(token, "principal-a", ~U[2026-07-18 00:00:05Z])

    assert payload.name == "CAM A"

    assert {:error, "NDI_DISCOVERY_UNAVAILABLE", _} =
             Capabilities.resolve_selection_token(token, "other", ~U[2026-07-18 00:00:05Z])
  end

  test "request_refresh rate-limits but still returns generation" do
    Application.put_env(:hydra_srt, :ndi, enabled: true)

    parent = self()
    refresh_fun = fn -> send(parent, :refreshed) end
    now = ~U[2026-07-18 00:00:00Z]

    assert {:ok, %{generation: gen1}} =
             Capabilities.request_refresh(
               principal: "rate-p",
               refresh_fun: refresh_fun,
               now: now
             )

    assert_receive :refreshed, 50

    assert {:ok, %{generation: gen2}} =
             Capabilities.request_refresh(
               principal: "rate-p",
               refresh_fun: refresh_fun,
               now: DateTime.add(now, 500, :millisecond)
             )

    refute_receive :refreshed, 50
    assert is_binary(gen1)
    assert is_binary(gen2)
  end

  test "q filter narrows source list" do
    Application.put_env(:hydra_srt, :ndi, enabled: true)

    snapshot = %{
      devices: [
        %{"display_name" => "Studio Cam", "properties" => ""},
        %{"display_name" => "Lobby", "properties" => ""}
      ],
      stale: false,
      capability: %{ok: true, reason_code: nil},
      truncated: false
    }

    assert {:ok, %{data: data}} =
             Capabilities.list_sources(
               principal: "p",
               q: "studio",
               snapshot_fun: fn -> snapshot end
             )

    assert Enum.map(data, & &1.name) == ["Studio Cam"]
  end
end

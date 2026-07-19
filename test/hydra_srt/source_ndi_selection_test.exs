defmodule HydraSrt.SourceNdiSelectionTest do
  use ExUnit.Case, async: false

  alias HydraSrt.Ndi.Capabilities
  alias HydraSrt.SourceNdiSelection

  setup do
    previous = Application.get_env(:hydra_srt, :ndi, :__unset__)

    on_exit(fn ->
      case previous do
        :__unset__ -> Application.delete_env(:hydra_srt, :ndi)
        value -> Application.put_env(:hydra_srt, :ndi, value)
      end
    end)

    Application.put_env(:hydra_srt, :ndi, enabled: true, receive: true, send: true)
    :ok
  end

  test "discovery_name resolves selection_token into snapshot fields and strips the token" do
    now = ~U[2026-07-19 10:00:00Z]
    expires = DateTime.add(now, 60, :second)
    principal = "principal-x4"

    token =
      Capabilities.mint_selection_token(
        principal,
        "gen-1",
        %{name: "STUDIO (Cam1)", url_address: "192.0.2.40:5961"},
        expires
      )

    assert {:ok, attrs} =
             SourceNdiSelection.apply_rest_selection(
               %{
                 "schema" => "NDI",
                 "ndi_selection_mode" => "discovery_name",
                 "ndi_source_name" => "STUDIO (Cam1)",
                 "selection_token" => token,
                 "name" => "src"
               },
               principal,
               now
             )

    assert attrs["ndi_source_name"] == "STUDIO (Cam1)"
    assert attrs["ndi_observed_address_snapshot"] == "192.0.2.40:5961"
    assert attrs["ndi_selection_observed_at"] == DateTime.truncate(now, :second)
    assert attrs["ndi_source_address"] == nil
    refute Map.has_key?(attrs, "selection_token")
  end

  test "expired selection_token returns a stable error" do
    now = ~U[2026-07-19 10:00:00Z]
    expires = DateTime.add(now, 5, :second)
    principal = "principal-x4-exp"

    token =
      Capabilities.mint_selection_token(
        principal,
        "gen-1",
        %{name: "CAM", url_address: "192.0.2.1:5961"},
        expires
      )

    assert {:error, "NDI_DISCOVERY_UNAVAILABLE", message, errors} =
             SourceNdiSelection.apply_rest_selection(
               %{
                 "schema" => "NDI",
                 "ndi_selection_mode" => "discovery_name",
                 "selection_token" => token
               },
               principal,
               DateTime.add(now, 30, :second)
             )

    assert is_binary(message)
    assert is_map(errors)
    assert Map.has_key?(errors, "selection_token")
  end

  test "mismatched ndi_source_name against token returns a stable error" do
    now = ~U[2026-07-19 10:00:00Z]
    expires = DateTime.add(now, 60, :second)
    principal = "principal-x4-mis"

    token =
      Capabilities.mint_selection_token(
        principal,
        "gen-1",
        %{name: "RIGHT NAME", url_address: "192.0.2.2:5961"},
        expires
      )

    assert {:error, "NDI_DISCOVERY_UNAVAILABLE", _message, errors} =
             SourceNdiSelection.apply_rest_selection(
               %{
                 "schema" => "NDI",
                 "ndi_selection_mode" => "discovery_name",
                 "ndi_source_name" => "WRONG NAME",
                 "selection_token" => token
               },
               principal,
               now
             )

    assert errors["selection_token"]
    assert errors["ndi_source_name"]
  end

  test "direct_address persists observed_name snapshot when available and strips token" do
    now = ~U[2026-07-19 11:00:00Z]

    assert {:ok, attrs} =
             SourceNdiSelection.apply_rest_selection(
               %{
                 "schema" => "NDI",
                 "ndi_selection_mode" => "direct_address",
                 "ndi_source_address" => "192.0.2.55:5961",
                 "ndi_observed_name_snapshot" => "DIRECT (Cam)",
                 "selection_token" => "must-not-persist"
               },
               "principal-x4-direct",
               now
             )

    assert attrs["ndi_source_address"] == "192.0.2.55:5961"
    assert attrs["ndi_source_name"] == nil
    assert attrs["ndi_observed_name_snapshot"] == "DIRECT (Cam)"
    assert attrs["ndi_observed_address_snapshot"] == nil
    assert attrs["ndi_selection_observed_at"] == DateTime.truncate(now, :second)
    refute Map.has_key?(attrs, "selection_token")
  end
end

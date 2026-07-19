defmodule HydraSrt.Mcp.NdiSchemaTest do
  use HydraSrt.DataCase, async: false

  import HydraSrt.DbFixtures

  alias HydraSrt.Api.Endpoint
  alias HydraSrt.Mcp.InputSchema
  alias HydraSrt.Mcp.ToolRegistry
  alias HydraSrt.Mcp.Tools.Destinations
  alias HydraSrt.Mcp.Tools.Sources

  @valid_ndi_source %{
    "name" => "mcp-ndi-source",
    "schema" => "NDI",
    "ndi_selection_mode" => "discovery_name",
    "ndi_source_name" => "CAMERA (Studio)",
    "ndi_media_policy" => "video_and_audio_required",
    "ndi_bandwidth" => "highest",
    "ndi_color_format" => "uyvy-bgra",
    "ndi_timestamp_mode" => "receive-time-vs-timestamp",
    "ndi_connect_timeout_ms" => 10_000,
    "ndi_receive_timeout_ms" => 5_000,
    "ndi_track_discovery_timeout_ms" => 10_000,
    "ndi_max_queue_length" => 4
  }

  @valid_ndi_destination %{
    "name" => "mcp-ndi-dest",
    "schema" => "NDI",
    "enabled" => true,
    "ndi_sender_name" => "Hydra (MCP Output)",
    "ndi_media_policy" => "video_only"
  }

  test "source schema mirrors Endpoint NDI allowlists and bounds" do
    props = InputSchema.source_attributes_schema()["properties"]

    assert props["schema"]["enum"] == Endpoint.source_schemas()
    assert props["ndi_selection_mode"]["enum"] == Endpoint.ndi_selection_modes()
    assert props["ndi_media_policy"]["enum"] == Endpoint.ndi_media_policies()
    assert props["ndi_bandwidth"]["enum"] == Endpoint.ndi_bandwidths()
    assert props["ndi_color_format"]["enum"] == Endpoint.ndi_color_formats()
    assert props["ndi_timestamp_mode"]["enum"] == Endpoint.ndi_timestamp_modes()

    assert props["ndi_connect_timeout_ms"]["minimum"] == Endpoint.ndi_timeout_ms_min()
    assert props["ndi_connect_timeout_ms"]["maximum"] == Endpoint.ndi_timeout_ms_max()
    assert props["ndi_receive_timeout_ms"]["minimum"] == Endpoint.ndi_timeout_ms_min()
    assert props["ndi_receive_timeout_ms"]["maximum"] == Endpoint.ndi_timeout_ms_max()
    assert props["ndi_track_discovery_timeout_ms"]["minimum"] == Endpoint.ndi_timeout_ms_min()
    assert props["ndi_track_discovery_timeout_ms"]["maximum"] == Endpoint.ndi_timeout_ms_max()
    assert props["ndi_max_queue_length"]["minimum"] == Endpoint.ndi_max_queue_length_min()
    assert props["ndi_max_queue_length"]["maximum"] == Endpoint.ndi_max_queue_length_max()

    refute Map.has_key?(props, "ndi_sender_name")
    refute Map.has_key?(props, "ndi_sender_name_key")
    refute Map.has_key?(props, "ndi_observed_address_snapshot")
    refute Map.has_key?(props, "props")
    refute Map.has_key?(props, "element_type")
  end

  test "destination schema mirrors Endpoint NDI allowlists" do
    props = InputSchema.destination_attributes_schema()["properties"]

    assert props["schema"]["enum"] == Endpoint.destination_schemas()
    assert props["ndi_media_policy"]["enum"] == Endpoint.ndi_media_policies()
    assert Map.has_key?(props, "ndi_sender_name")
    refute Map.has_key?(props, "ndi_source_name")
    refute Map.has_key?(props, "ndi_source_address")
    refute Map.has_key?(props, "ndi_selection_mode")
    refute Map.has_key?(props, "ndi_sender_name_key")
    refute Map.has_key?(props, "props")
  end

  test "create/update tool definitions expose typed NDI source and destination objects" do
    create_source =
      Enum.find(Sources.definitions(), &(&1.name == "create_source"))

    update_source =
      Enum.find(Sources.definitions(), &(&1.name == "update_source"))

    create_destination =
      Enum.find(Destinations.definitions(), &(&1.name == "create_destination"))

    assert create_source.input_schema["properties"]["source"]["properties"][
             "ndi_selection_mode"
           ]["enum"] == Endpoint.ndi_selection_modes()

    assert update_source.input_schema["properties"]["source"]["properties"][
             "ndi_bandwidth"
           ]["enum"] == Endpoint.ndi_bandwidths()

    assert create_destination.input_schema["properties"]["destination"]["properties"][
             "ndi_sender_name"
           ]["type"] == "string"
  end

  test "MCP tool registry does not expose NDI discovery refresh or probe tools" do
    names = ToolRegistry.tool_names()

    refute "refresh_ndi_discovery" in names
    refute "ndi_discovery_refresh" in names
    refute "list_ndi_sources" in names
    refute "create_ndi_probe" in names
    refute "ndi_probe" in names
    refute Enum.any?(names, &String.contains?(&1, "ndi_discovery"))
    refute Enum.any?(names, &String.contains?(&1, "ndi_probe"))
  end

  test "sanitize drops observed identity, derived key, and raw GStreamer props" do
    sanitized =
      InputSchema.sanitize_source_attrs(%{
        "name" => "x",
        "ndi_source_name" => "CAM",
        "ndi_sender_name" => "should-drop",
        "ndi_sender_name_key" => "attacker",
        "ndi_observed_address_snapshot" => "192.0.2.1:5960",
        "ndi_observed_name_snapshot" => "CAM",
        "ndi_selection_observed_at" => "2026-07-19T00:00:00Z",
        "props" => %{"ndi-name" => "raw"},
        "element_type" => "ndisrc",
        "legacy" => %{"element_type" => "ndisrc"}
      })

    assert sanitized["ndi_source_name"] == "CAM"
    refute Map.has_key?(sanitized, "ndi_sender_name")
    refute Map.has_key?(sanitized, "ndi_sender_name_key")
    refute Map.has_key?(sanitized, "ndi_observed_address_snapshot")
    refute Map.has_key?(sanitized, "ndi_observed_name_snapshot")
    refute Map.has_key?(sanitized, "ndi_selection_observed_at")
    refute Map.has_key?(sanitized, "props")
    refute Map.has_key?(sanitized, "element_type")
    refute Map.has_key?(sanitized, "legacy")
  end

  test "MCP create_source accepts valid NDI discovery_name through Endpoint changeset" do
    route = route_fixture()

    assert {:ok, response} =
             ToolRegistry.dispatch("create_source", %{
               "route_id" => route["id"],
               "source" => @valid_ndi_source
             })

    assert response.isError == false
    data = response.structured_content["data"]
    assert data["schema"] == "NDI"
    assert data["ndi_selection_mode"] == "discovery_name"
    assert data["ndi_source_name"] == "CAMERA (Studio)"
    assert data["ndi_source_address"] == nil
    refute Map.has_key?(data, "ndi_sender_name_key")
  end

  test "MCP create_source accepts valid NDI direct_address through Endpoint changeset" do
    route = route_fixture()

    attrs =
      @valid_ndi_source
      |> Map.put("ndi_selection_mode", "direct_address")
      |> Map.delete("ndi_source_name")
      |> Map.put("ndi_source_address", "192.0.2.10:5961")

    assert {:ok, response} =
             ToolRegistry.dispatch("create_source", %{
               "route_id" => route["id"],
               "source" => attrs
             })

    assert response.isError == false
    data = response.structured_content["data"]
    assert data["ndi_selection_mode"] == "direct_address"
    assert data["ndi_source_address"] == "192.0.2.10:5961"
    assert data["ndi_source_name"] == nil
  end

  test "MCP create_source rejects both name and address" do
    route = route_fixture()

    attrs =
      Map.merge(@valid_ndi_source, %{
        "ndi_source_name" => "CAM",
        "ndi_source_address" => "192.0.2.10:5961"
      })

    assert {:ok, response} =
             ToolRegistry.dispatch("create_source", %{
               "route_id" => route["id"],
               "source" => attrs
             })

    assert response.isError == true
    errors = response.structured_content["errors"]
    assert is_map(errors)
    assert Map.has_key?(errors, "ndi_source_name") or Map.has_key?(errors, "ndi_source_address")
  end

  test "MCP create_source rejects bad NDI enums" do
    route = route_fixture()

    attrs =
      Map.merge(@valid_ndi_source, %{
        "ndi_selection_mode" => "by_token",
        "ndi_media_policy" => "both",
        "ndi_bandwidth" => "metadata_only",
        "ndi_color_format" => "nv12",
        "ndi_timestamp_mode" => "not-a-mode"
      })

    assert {:ok, response} =
             ToolRegistry.dispatch("create_source", %{
               "route_id" => route["id"],
               "source" => attrs
             })

    assert response.isError == true
    errors = response.structured_content["errors"]
    assert Map.has_key?(errors, "ndi_selection_mode")
    assert Map.has_key?(errors, "ndi_media_policy")
    assert Map.has_key?(errors, "ndi_bandwidth")
    assert Map.has_key?(errors, "ndi_color_format")
    assert Map.has_key?(errors, "ndi_timestamp_mode")
  end

  test "MCP create_source rejects out-of-range timeouts and queue length" do
    route = route_fixture()

    low =
      Map.merge(@valid_ndi_source, %{
        "ndi_connect_timeout_ms" => 999,
        "ndi_max_queue_length" => 0
      })

    high =
      Map.merge(@valid_ndi_source, %{
        "ndi_receive_timeout_ms" => 60_001,
        "ndi_track_discovery_timeout_ms" => 60_001,
        "ndi_max_queue_length" => 65
      })

    assert {:ok, low_response} =
             ToolRegistry.dispatch("create_source", %{
               "route_id" => route["id"],
               "source" => low
             })

    assert low_response.isError == true
    low_errors = low_response.structured_content["errors"]
    assert Map.has_key?(low_errors, "ndi_connect_timeout_ms")
    assert Map.has_key?(low_errors, "ndi_max_queue_length")

    assert {:ok, high_response} =
             ToolRegistry.dispatch("create_source", %{
               "route_id" => route["id"],
               "source" => high
             })

    assert high_response.isError == true
    high_errors = high_response.structured_content["errors"]
    assert Map.has_key?(high_errors, "ndi_receive_timeout_ms")
    assert Map.has_key?(high_errors, "ndi_track_discovery_timeout_ms")
    assert Map.has_key?(high_errors, "ndi_max_queue_length")
  end

  test "MCP create_destination accepts valid NDI through Endpoint changeset" do
    route = route_fixture()

    assert {:ok, response} =
             ToolRegistry.dispatch("create_destination", %{
               "route_id" => route["id"],
               "destination" => @valid_ndi_destination
             })

    assert response.isError == false
    data = response.structured_content["data"]
    assert data["schema"] == "NDI"
    assert data["ndi_sender_name"] == "Hydra (MCP Output)"
    assert data["ndi_media_policy"] == "video_only"
    assert data["ndi_source_name"] == nil
    refute Map.has_key?(data, "ndi_sender_name_key")
  end

  test "MCP create_destination rejects blank sender name" do
    route = route_fixture()

    attrs = Map.put(@valid_ndi_destination, "ndi_sender_name", "   ")

    assert {:ok, response} =
             ToolRegistry.dispatch("create_destination", %{
               "route_id" => route["id"],
               "destination" => attrs
             })

    assert response.isError == true
    assert Map.has_key?(response.structured_content["errors"], "ndi_sender_name")
  end

  test "MCP create_source ignores smuggled observed snapshots and raw props" do
    route = route_fixture()

    attrs =
      Map.merge(@valid_ndi_source, %{
        "ndi_observed_address_snapshot" => "192.0.2.1:5960",
        "ndi_observed_name_snapshot" => "CAMERA (Studio)",
        "ndi_sender_name_key" => "attacker-key",
        "props" => %{"bandwidth" => 100},
        "element_type" => "ndisrc"
      })

    assert {:ok, response} =
             ToolRegistry.dispatch("create_source", %{
               "route_id" => route["id"],
               "source" => attrs
             })

    assert response.isError == false
    data = response.structured_content["data"]
    assert data["ndi_observed_address_snapshot"] == nil
    assert data["ndi_observed_name_snapshot"] == nil
    refute Map.has_key?(data, "props")
    refute Map.has_key?(data, "element_type")
  end
end

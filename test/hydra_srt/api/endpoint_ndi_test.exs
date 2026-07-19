defmodule HydraSrt.Api.EndpointNdiTest do
  use HydraSrt.DataCase

  alias HydraSrt.Api.Endpoint
  alias HydraSrt.Db
  alias HydraSrt.Repo

  import HydraSrt.ApiFixtures

  @valid_ndi_source_attrs %{
    schema: "NDI",
    ndi_selection_mode: "discovery_name",
    ndi_source_name: "CAMERA (Studio)",
    ndi_media_policy: "video_and_audio_required",
    ndi_bandwidth: "highest",
    ndi_color_format: "uyvy-bgra",
    ndi_timestamp_mode: "receive-time-vs-timestamp",
    ndi_connect_timeout_ms: 10_000,
    ndi_receive_timeout_ms: 5_000,
    ndi_track_discovery_timeout_ms: 10_000,
    ndi_max_queue_length: 4
  }

  test "migration left existing non-NDI rows with nil NDI columns" do
    route = route_fixture()
    source = source_fixture(route, %{schema: "UDP", host: "127.0.0.1", port: 5501})
    reloaded = Repo.get!(Endpoint, source.id)

    assert reloaded.ndi_source_name == nil
    assert reloaded.ndi_source_address == nil
    assert reloaded.ndi_selection_mode == nil
    assert reloaded.ndi_sender_name == nil
    assert reloaded.ndi_sender_name_key == nil
    assert reloaded.ndi_media_policy == nil
    assert reloaded.ndi_connect_timeout_ms == nil
  end

  test "migration created partial unique index for enabled NDI destinations" do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT name, sql FROM sqlite_master
        WHERE type = 'index'
          AND name = 'endpoints_ndi_sender_name_key_enabled_dest_index'
        """,
        []
      )

    assert [[name, sql]] = rows
    assert name == "endpoints_ndi_sender_name_key_enabled_dest_index"
    assert sql =~ "schema = 'NDI'"
    assert sql =~ "type = 'destination'"
    assert sql =~ "enabled = 1"
    assert sql =~ "ndi_sender_name_key IS NOT NULL"
  end

  test "valid NDI source changeset with discovery_name" do
    route = route_fixture()

    changeset =
      Endpoint.source_changeset(
        %Endpoint{},
        Map.merge(@valid_ndi_source_attrs, %{route_id: route.id, position: 0})
      )

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :ndi_sender_name_key) == nil
    assert Ecto.Changeset.get_field(changeset, :bind_port) == nil
  end

  test "valid NDI source changeset with direct_address IPv4 and IPv6" do
    route = route_fixture()

    ipv4 =
      Endpoint.source_changeset(%Endpoint{}, %{
        route_id: route.id,
        position: 0,
        schema: "NDI",
        ndi_selection_mode: "direct_address",
        ndi_source_address: "192.0.2.10:5961"
      })

    ipv6 =
      Endpoint.source_changeset(%Endpoint{}, %{
        route_id: route.id,
        position: 1,
        schema: "NDI",
        ndi_selection_mode: "direct_address",
        ndi_source_address: "[2001:db8::1]:5961"
      })

    assert ipv4.valid?
    assert ipv6.valid?
  end

  test "rejects NDI source with both name and address" do
    route = route_fixture()

    discovery =
      Endpoint.source_changeset(%Endpoint{}, %{
        route_id: route.id,
        position: 0,
        schema: "NDI",
        ndi_selection_mode: "discovery_name",
        ndi_source_name: "CAM",
        ndi_source_address: "192.0.2.10:5961"
      })

    direct =
      Endpoint.source_changeset(%Endpoint{}, %{
        route_id: route.id,
        position: 1,
        schema: "NDI",
        ndi_selection_mode: "direct_address",
        ndi_source_name: "CAM",
        ndi_source_address: "192.0.2.10:5961"
      })

    refute discovery.valid?

    assert {"must be blank when selection mode is discovery_name", _} =
             discovery.errors[:ndi_source_address]

    refute direct.valid?

    assert {"must be blank when selection mode is direct_address", _} =
             direct.errors[:ndi_source_name]
  end

  test "rejects NDI source with neither name nor address" do
    route = route_fixture()

    discovery =
      Endpoint.source_changeset(%Endpoint{}, %{
        route_id: route.id,
        position: 0,
        schema: "NDI",
        ndi_selection_mode: "discovery_name"
      })

    direct =
      Endpoint.source_changeset(%Endpoint{}, %{
        route_id: route.id,
        position: 1,
        schema: "NDI",
        ndi_selection_mode: "direct_address"
      })

    refute discovery.valid?
    assert {"can't be blank", _} = discovery.errors[:ndi_source_name]
    refute direct.valid?
    assert {"can't be blank", _} = direct.errors[:ndi_source_address]
  end

  test "rejects DNS hostnames and malformed NDI source addresses" do
    route = route_fixture()

    for address <- ["localhost:5960", "camera.local:5960", "192.0.2.10", "[::1]", "not-an-ip:x"] do
      changeset =
        Endpoint.source_changeset(%Endpoint{}, %{
          route_id: route.id,
          position: 0,
          schema: "NDI",
          ndi_selection_mode: "direct_address",
          ndi_source_address: address
        })

      refute changeset.valid?, "expected #{inspect(address)} to be rejected"
      assert Keyword.has_key?(changeset.errors, :ndi_source_address)
    end
  end

  test "rejects invalid NDI selection mode and allowlist values" do
    route = route_fixture()

    changeset =
      Endpoint.source_changeset(%Endpoint{}, %{
        route_id: route.id,
        position: 0,
        schema: "NDI",
        ndi_selection_mode: "by_token",
        ndi_source_name: "CAM",
        ndi_media_policy: "both",
        ndi_bandwidth: "metadata_only",
        ndi_color_format: "nv12",
        ndi_timestamp_mode: "phase-1-selected-mode"
      })

    refute changeset.valid?
    assert {"is invalid", _} = changeset.errors[:ndi_selection_mode]
    assert {"is invalid", _} = changeset.errors[:ndi_media_policy]
    assert {"is invalid", _} = changeset.errors[:ndi_bandwidth]
    assert {"is invalid", _} = changeset.errors[:ndi_color_format]
    assert {"is invalid", _} = changeset.errors[:ndi_timestamp_mode]
  end

  test "rejects invalid ndi_timestamp_mode and accepts allowlisted modes" do
    route = route_fixture()

    invalid =
      Endpoint.source_changeset(
        %Endpoint{},
        Map.merge(@valid_ndi_source_attrs, %{
          route_id: route.id,
          position: 0,
          ndi_timestamp_mode: "not-a-mode"
        })
      )

    refute invalid.valid?
    assert {"is invalid", _} = invalid.errors[:ndi_timestamp_mode]

    for {mode, position} <-
          Enum.with_index(~w(auto receive-time timecode timestamp receive-time-vs-timestamp)) do
      changeset =
        Endpoint.source_changeset(
          %Endpoint{},
          Map.merge(@valid_ndi_source_attrs, %{
            route_id: route.id,
            position: position,
            ndi_timestamp_mode: mode
          })
        )

      assert changeset.valid?, "expected #{inspect(mode)} to be accepted"
    end

    omitted =
      Endpoint.source_changeset(
        %Endpoint{},
        Map.merge(@valid_ndi_source_attrs, %{
          route_id: route.id,
          position: 10,
          ndi_timestamp_mode: nil
        })
      )

    assert omitted.valid?
    assert Ecto.Changeset.get_field(omitted, :ndi_timestamp_mode) == nil
  end

  test "rejects out-of-range NDI timeouts and queue length" do
    route = route_fixture()

    low =
      Endpoint.source_changeset(
        %Endpoint{},
        Map.merge(@valid_ndi_source_attrs, %{
          route_id: route.id,
          position: 0,
          ndi_connect_timeout_ms: 999,
          ndi_max_queue_length: 0
        })
      )

    high =
      Endpoint.source_changeset(
        %Endpoint{},
        Map.merge(@valid_ndi_source_attrs, %{
          route_id: route.id,
          position: 1,
          ndi_receive_timeout_ms: 60_001,
          ndi_track_discovery_timeout_ms: 60_001,
          ndi_max_queue_length: 65
        })
      )

    refute low.valid?
    assert Keyword.has_key?(low.errors, :ndi_connect_timeout_ms)
    assert Keyword.has_key?(low.errors, :ndi_max_queue_length)
    refute high.valid?
    assert Keyword.has_key?(high.errors, :ndi_receive_timeout_ms)
    assert Keyword.has_key?(high.errors, :ndi_track_discovery_timeout_ms)
    assert Keyword.has_key?(high.errors, :ndi_max_queue_length)
  end

  test "accepts inclusive NDI timeout and queue bounds" do
    route = route_fixture()

    changeset =
      Endpoint.source_changeset(
        %Endpoint{},
        Map.merge(@valid_ndi_source_attrs, %{
          route_id: route.id,
          position: 0,
          ndi_connect_timeout_ms: 1000,
          ndi_receive_timeout_ms: 60_000,
          ndi_track_discovery_timeout_ms: 1000,
          ndi_max_queue_length: 1
        })
      )

    assert changeset.valid?

    max_queue =
      Endpoint.source_changeset(
        %Endpoint{},
        Map.merge(@valid_ndi_source_attrs, %{
          route_id: route.id,
          position: 1,
          ndi_max_queue_length: 64
        })
      )

    assert max_queue.valid?
  end

  test "valid NDI destination derives sender name key and clears bind target" do
    route = route_fixture()

    changeset =
      Endpoint.destination_changeset(%Endpoint{}, %{
        route_id: route.id,
        schema: "NDI",
        enabled: true,
        ndi_sender_name: "  Hydra   (Route Output) ",
        ndi_media_policy: "audio_only"
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :ndi_sender_name) == "Hydra   (Route Output)"
    assert Ecto.Changeset.get_field(changeset, :ndi_sender_name_key) == "hydra (route output)"
    assert Ecto.Changeset.get_field(changeset, :bind_interface) == nil
    assert Ecto.Changeset.get_field(changeset, :bind_address) == nil
    assert Ecto.Changeset.get_field(changeset, :bind_port) == nil
  end

  test "NDI destination clears source-direction fields and keeps media_policy" do
    route = route_fixture()
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    changeset =
      Endpoint.destination_changeset(%Endpoint{}, %{
        route_id: route.id,
        schema: "NDI",
        enabled: true,
        ndi_sender_name: "Hydra Output",
        ndi_media_policy: "video_only",
        ndi_source_name: "CAMERA (Studio)",
        ndi_source_address: "192.0.2.10:5961",
        ndi_selection_mode: "discovery_name",
        ndi_observed_address_snapshot: "192.0.2.10:5961",
        ndi_observed_name_snapshot: "CAMERA (Studio)",
        ndi_selection_observed_at: observed_at,
        ndi_receiver_name: "Hydra Receiver",
        ndi_bandwidth: "highest",
        ndi_color_format: "uyvy-bgra",
        ndi_timestamp_mode: "receive-time-vs-timestamp",
        ndi_connect_timeout_ms: 10_000,
        ndi_receive_timeout_ms: 5_000,
        ndi_track_discovery_timeout_ms: 10_000,
        ndi_max_queue_length: 4
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :ndi_sender_name) == "Hydra Output"
    assert Ecto.Changeset.get_field(changeset, :ndi_sender_name_key) == "hydra output"
    assert Ecto.Changeset.get_field(changeset, :ndi_media_policy) == "video_only"

    for field <- [
          :ndi_source_name,
          :ndi_source_address,
          :ndi_selection_mode,
          :ndi_observed_address_snapshot,
          :ndi_observed_name_snapshot,
          :ndi_selection_observed_at,
          :ndi_receiver_name,
          :ndi_bandwidth,
          :ndi_color_format,
          :ndi_timestamp_mode,
          :ndi_connect_timeout_ms,
          :ndi_receive_timeout_ms,
          :ndi_track_discovery_timeout_ms,
          :ndi_max_queue_length
        ] do
      assert Ecto.Changeset.get_field(changeset, field) == nil,
             "expected destination to clear #{field}"
    end
  end

  test "ndi_sender_name_key uses trim, whitespace collapse, NFC, and casefold" do
    composed = "Café Output"
    decomposed = "Cafe\u0301 Output"

    assert Endpoint.normalize_ndi_sender_name_key(composed) ==
             Endpoint.normalize_ndi_sender_name_key(decomposed)

    assert Endpoint.normalize_ndi_sender_name_key("  Hydra\t\tOUT  ") == "hydra out"
    assert Endpoint.normalize_ndi_sender_name_key("HYDRA OUT") == "hydra out"
  end

  test "rejects blank NDI destination sender name" do
    route = route_fixture()

    changeset =
      Endpoint.destination_changeset(%Endpoint{}, %{
        route_id: route.id,
        schema: "NDI",
        ndi_sender_name: "   "
      })

    refute changeset.valid?
    assert {"can't be blank", _} = changeset.errors[:ndi_sender_name]
  end

  test "never casts ndi_sender_name_key from input" do
    route = route_fixture()

    changeset =
      Endpoint.destination_changeset(%Endpoint{}, %{
        route_id: route.id,
        schema: "NDI",
        ndi_sender_name: "Hydra Output",
        ndi_sender_name_key: "attacker-supplied-key"
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :ndi_sender_name_key) == "hydra output"
  end

  test "rejects duplicate enabled NDI destination sender name keys with friendly error" do
    route = route_fixture()

    assert {:ok, _first} =
             %Endpoint{}
             |> Endpoint.destination_changeset(%{
               route_id: route.id,
               position: 0,
               schema: "NDI",
               enabled: true,
               ndi_sender_name: "Hydra Output"
             })
             |> Repo.insert()

    assert {:error, changeset} =
             %Endpoint{}
             |> Endpoint.destination_changeset(%{
               route_id: route.id,
               position: 1,
               schema: "NDI",
               enabled: true,
               ndi_sender_name: "  hydra   output "
             })
             |> Repo.insert()

    assert {"NDI sender name is already in use by an enabled destination", _} =
             changeset.errors[:ndi_sender_name_key]
  end

  test "allows duplicate NDI sender keys when an existing destination is disabled" do
    route = route_fixture()

    assert {:ok, _disabled} =
             %Endpoint{}
             |> Endpoint.destination_changeset(%{
               route_id: route.id,
               position: 0,
               schema: "NDI",
               enabled: false,
               ndi_sender_name: "Shared Name"
             })
             |> Repo.insert()

    assert {:ok, _enabled} =
             %Endpoint{}
             |> Endpoint.destination_changeset(%{
               route_id: route.id,
               position: 1,
               schema: "NDI",
               enabled: true,
               ndi_sender_name: "Shared Name"
             })
             |> Repo.insert()
  end

  test "clears NDI fields for non-NDI schemas" do
    route = route_fixture()
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    changeset =
      Endpoint.source_changeset(%Endpoint{}, %{
        route_id: route.id,
        position: 0,
        schema: "UDP",
        host: "127.0.0.1",
        port: 5600,
        ndi_source_name: "stale",
        ndi_source_address: "192.0.2.10:5961",
        ndi_selection_mode: "discovery_name",
        ndi_observed_address_snapshot: "192.0.2.10:5961",
        ndi_observed_name_snapshot: "stale",
        ndi_selection_observed_at: observed_at,
        ndi_receiver_name: "stale-receiver",
        ndi_sender_name: "stale-sender",
        ndi_media_policy: "video_only",
        ndi_bandwidth: "highest",
        ndi_color_format: "uyvy-bgra",
        ndi_timestamp_mode: "auto",
        ndi_connect_timeout_ms: 5000,
        ndi_receive_timeout_ms: 5000,
        ndi_track_discovery_timeout_ms: 5000,
        ndi_max_queue_length: 4
      })

    assert changeset.valid?

    for field <- Endpoint.ndi_fields() do
      assert Ecto.Changeset.get_field(changeset, field) == nil,
             "expected non-NDI schema to clear #{field}"
    end
  end

  test "serializers include NDI intent fields and exclude ndi_sender_name_key" do
    source = %Endpoint{
      id: Ecto.UUID.generate(),
      route_id: Ecto.UUID.generate(),
      enabled: true,
      schema: "NDI",
      ndi_selection_mode: "discovery_name",
      ndi_source_name: "CAM",
      ndi_media_policy: "video_only",
      ndi_bandwidth: "highest",
      ndi_color_format: "fastest",
      ndi_connect_timeout_ms: 1000,
      ndi_receive_timeout_ms: 2000,
      ndi_track_discovery_timeout_ms: 3000,
      ndi_max_queue_length: 8,
      ndi_sender_name_key: "must-not-appear",
      allowed_list: "[]",
      denied_list: "[]"
    }

    destination = %Endpoint{
      id: Ecto.UUID.generate(),
      route_id: Ecto.UUID.generate(),
      enabled: true,
      schema: "NDI",
      ndi_sender_name: "Hydra Out",
      ndi_media_policy: "audio_only",
      ndi_sender_name_key: "hydra out",
      allowed_list: "[]",
      denied_list: "[]"
    }

    source_map = Db.source_to_map(source)
    destination_map = Db.destination_to_map(destination)

    assert source_map["ndi_selection_mode"] == "discovery_name"
    assert source_map["ndi_source_name"] == "CAM"
    assert source_map["ndi_media_policy"] == "video_only"
    assert source_map["ndi_max_queue_length"] == 8
    refute Map.has_key?(source_map, "ndi_sender_name_key")

    assert destination_map["ndi_sender_name"] == "Hydra Out"
    assert destination_map["ndi_media_policy"] == "audio_only"
    refute Map.has_key?(destination_map, "ndi_sender_name_key")
  end
end

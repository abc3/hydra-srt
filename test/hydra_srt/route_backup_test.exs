defmodule HydraSrt.RouteBackupTest do
  use HydraSrt.DataCase

  import Ecto.Query

  alias HydraSrt.Api.Endpoint
  alias HydraSrt.Db
  alias HydraSrt.Repo
  alias HydraSrt.RouteBackup

  import HydraSrt.DbFixtures

  test "exports a portable versioned route backup without runtime fields" do
    route =
      route_fixture(%{
        "enabled" => false,
        "name" => "Contribution",
        "tags" => ["production"]
      })

    source =
      source_fixture(route, %{
        "name" => "Primary",
        "schema" => "SRT",
        "mode" => "listener",
        "localport" => 4200,
        "passphrase" => "secret-passphrase"
      })

    _destination = destination_fixture(route, %{"name" => "Decoder"})
    {:ok, _route} = Db.set_route_active_source(route["id"], source["id"], "manual")

    assert {:ok, backup} = RouteBackup.export()
    assert backup["backup_version"] == "1.0"
    assert is_binary(backup["product_version"])

    [exported] = backup["routes"]
    assert exported["name"] == "Contribution"
    assert exported["tags"] == ["production"]
    assert get_in(exported, ["sources", Access.at(0), "passphrase"]) == "secret-passphrase"
    refute Map.has_key?(exported, "id")
    refute Map.has_key?(exported, "status")
    refute Map.has_key?(hd(exported["sources"]), "route_id")
    refute Map.has_key?(hd(exported["sources"]), "last_probe_at")
  end

  test "serializes route export through the backup coordinator" do
    parent = self()

    :meck.new(HydraSrt.BackupLock, [:passthrough])

    :meck.expect(HydraSrt.BackupLock, :run, fn operation ->
      send(parent, :backup_lock_used)
      operation.()
    end)

    on_exit(fn -> :meck.unload() end)

    assert {:ok, _backup} = RouteBackup.export()
    assert_receive :backup_lock_used
  end

  test "exports destinations in position order" do
    route = route_fixture(%{"enabled" => false, "name" => "Ordered outputs"})
    _source = source_fixture(route)
    _first = destination_fixture(route, %{"name" => "First", "position" => 0})
    _second = destination_fixture(route, %{"name" => "Second", "position" => 1})

    assert {:ok, %{"routes" => [exported]}} = RouteBackup.export()
    assert Enum.map(exported["destinations"], & &1["name"]) == ["First", "Second"]
  end

  test "imports a route backup atomically and replaces existing routes" do
    old_route = route_fixture(%{"enabled" => false, "name" => "Old route"})
    _old_source = source_fixture(old_route)

    backup = %{
      "backup_version" => "1.0",
      "product_version" => "0.6.1",
      "routes" => [
        %{
          "name" => "Imported route",
          "enabled" => false,
          "tags" => ["remote"],
          "sources" => [
            %{
              "name" => "Primary",
              "enabled" => true,
              "schema" => "UDP",
              "host" => "127.0.0.1",
              "port" => 5000
            }
          ],
          "destinations" => [
            %{
              "name" => "Primary output",
              "node" => "edge-a",
              "enabled" => true,
              "schema" => "UDP",
              "host" => "127.0.0.1",
              "port" => 5001
            },
            %{
              "name" => "Backup output",
              "enabled" => true,
              "schema" => "UDP",
              "host" => "127.0.0.1",
              "port" => 5002
            }
          ]
        }
      ]
    }

    assert {:ok, 1} = RouteBackup.import(backup)
    assert {:ok, [route]} = Db.get_all_routes(true)
    assert route["name"] == "Imported route"
    assert route["tags"] == ["remote"]
    assert length(route["sources"]) == 1

    destinations =
      Endpoint.destination_scope()
      |> where([endpoint], endpoint.route_id == ^route["id"])
      |> order_by([endpoint], asc: endpoint.position)
      |> Repo.all()

    assert Enum.map(destinations, &{&1.name, &1.position}) == [
             {"Primary output", 0},
             {"Backup output", 1}
           ]

    assert hd(destinations).node == "edge-a"
    refute route["id"] == old_route["id"]
  end

  test "restores the previous routes when an imported enabled route cannot start" do
    route = route_fixture(%{"enabled" => false, "name" => "Existing route"})
    _source = source_fixture(route)

    backup = %{
      "backup_version" => "1.0",
      "routes" => [
        %{
          "name" => "Imported route",
          "enabled" => true,
          "sources" => [
            %{
              "name" => "Primary",
              "enabled" => true,
              "schema" => "UDP",
              "host" => "127.0.0.1",
              "port" => 5000
            }
          ],
          "destinations" => []
        }
      ]
    }

    :meck.new(HydraSrt, [:passthrough])
    :meck.expect(HydraSrt, :start_route, fn _route_id -> {:error, :start_failed} end)

    on_exit(fn -> :meck.unload() end)

    assert {:error, "failed to start route " <> _rest} = RouteBackup.import(backup)
    assert {:ok, [restored]} = Db.get_all_routes(false)
    assert restored["name"] == "Existing route"
  end

  test "captures the rollback snapshot after routes stop" do
    route = route_fixture(%{"enabled" => false, "name" => "Existing route"})
    _source = source_fixture(route)

    backup = %{
      "backup_version" => "1.0",
      "routes" => [
        %{
          "name" => "Imported route",
          "enabled" => true,
          "sources" => [%{"name" => "Primary", "schema" => "UDP"}],
          "destinations" => []
        }
      ]
    }

    :meck.new(HydraSrt, [:passthrough])

    :meck.expect(HydraSrt, :stop_route, fn route_id ->
      {:ok, _route} = Db.update_route(route_id, %{"name" => "Changed while stopping"})
      :ok
    end)

    :meck.expect(HydraSrt, :start_route, fn _route_id -> {:error, :start_failed} end)

    on_exit(fn -> :meck.unload() end)

    assert {:error, "failed to start route " <> _rest} = RouteBackup.import(backup)
    assert {:ok, [restored]} = Db.get_all_routes(false)
    assert restored["name"] == "Changed while stopping"
  end

  test "does not replace routes when an existing route fails to stop" do
    route = route_fixture(%{"enabled" => false, "name" => "Existing route"})
    _source = source_fixture(route)

    backup = %{
      "backup_version" => "1.0",
      "routes" => [
        %{
          "name" => "Imported route",
          "enabled" => false,
          "sources" => [%{"name" => "Primary", "schema" => "UDP"}],
          "destinations" => []
        }
      ]
    }

    :meck.new(HydraSrt, [:passthrough])
    :meck.expect(HydraSrt, :stop_route, fn _route_id -> {:error, :timeout} end)

    on_exit(fn -> :meck.unload() end)

    assert {:error, {:route_stop_failed, route_id, :timeout}} = RouteBackup.import(backup)
    assert route_id == route["id"]
    assert {:ok, [existing]} = Db.get_all_routes(false)
    assert existing["id"] == route["id"]
  end

  test "rejects invalid presets without changing routes" do
    route = route_fixture(%{"enabled" => false, "name" => "Existing route"})
    _source = source_fixture(route)

    invalid = %{
      "backup_version" => "1.0",
      "routes" => [%{"name" => "Missing source", "sources" => []}]
    }

    assert {:error, :route_source_required} = RouteBackup.import(invalid)
    assert {:ok, [existing]} = Db.get_all_routes(false)
    assert existing["id"] == route["id"]
  end

  test "rolls back when an endpoint fails schema validation" do
    route = route_fixture(%{"enabled" => false, "name" => "Existing route"})
    _source = source_fixture(route)

    invalid = %{
      "backup_version" => "1.0",
      "routes" => [
        %{
          "name" => "Invalid route",
          "sources" => [%{"name" => "Primary", "schema" => "UNKNOWN"}],
          "destinations" => []
        }
      ]
    }

    assert {:error, %Ecto.Changeset{valid?: false}} = RouteBackup.import(invalid)
    assert {:ok, [existing]} = Db.get_all_routes(false)
    assert existing["id"] == route["id"]
  end

  test "restarts existing enabled routes when the replacement transaction raises" do
    route = route_fixture(%{"enabled" => true, "name" => "Existing route"})
    _source = source_fixture(route)

    backup = %{
      "backup_version" => "1.0",
      "routes" => [
        %{
          "name" => "Imported route",
          "enabled" => false,
          "sources" => [%{"name" => "Primary", "schema" => "UDP"}],
          "destinations" => []
        }
      ]
    }

    parent = self()

    :meck.new(HydraSrt, [:passthrough])
    :meck.expect(HydraSrt, :stop_route, fn _route_id -> :ok end)

    :meck.expect(HydraSrt, :start_route, fn route_id ->
      send(parent, {:route_restarted, route_id})
      {:ok, self()}
    end)

    :meck.new(Repo, [:passthrough])
    :meck.expect(Repo, :transaction, fn _operation -> raise "database failure" end)

    on_exit(fn -> :meck.unload() end)

    assert {:error, %RuntimeError{message: "database failure"}} = RouteBackup.import(backup)
    assert_receive {:route_restarted, route_id}
    assert route_id == route["id"]
    assert {:ok, [existing]} = Db.get_all_routes(false)
    assert existing["id"] == route["id"]
  end

  test "rejects unsupported route backup versions" do
    assert {:error, {:unsupported_backup_version, "2.0"}} =
             RouteBackup.import(%{"backup_version" => "2.0", "routes" => []})
  end
end

defmodule HydraSrt.Repo.Migrations.CreateEndpointsAndMigrateFromRoutes do
  use Ecto.Migration

  def up do
    alter table(:routes) do
      add :backup_config, :map, default: %{}, null: false
      add :last_switch_reason, :string
      add :last_switch_at, :utc_datetime_usec
    end

    create table(:endpoints, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :route_id, references(:routes, type: :binary_id, on_delete: :delete_all), null: false
      add :type, :string, null: false
      add :position, :integer, null: false, default: 0
      add :enabled, :boolean, default: false, null: false
      add :name, :string
      add :alias, :string
      add :status, :string
      add :schema, :string, null: false
      add :schema_options, :map, default: %{}, null: false
      add :node, :string
      add :started_at, :utc_datetime
      add :stopped_at, :utc_datetime
      add :lock_version, :integer, default: 1, null: false
      add :last_probe_at, :utc_datetime_usec
      add :last_failure_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:endpoints, [:route_id])
    create index(:endpoints, [:route_id, :type])

    create unique_index(:endpoints, [:route_id, :position, :type],
             name: :endpoints_route_id_position_type_index
           )

    execute("""
    INSERT INTO endpoints (id, route_id, type, position, enabled, name, schema, schema_options, status, last_probe_at, last_failure_at, inserted_at, updated_at)
    SELECT
      lower(hex(randomblob(4))) || '-' ||
      lower(hex(randomblob(2))) || '-' ||
      '4' || substr(lower(hex(randomblob(2))), 2) || '-' ||
      substr('89ab', abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))), 2) || '-' ||
      lower(hex(randomblob(6))),
      id,
      'source',
      0,
      1,
      NULL,
      COALESCE(schema, 'SRT'),
      COALESCE(schema_options, '{}'),
      NULL,
      NULL,
      NULL,
      inserted_at,
      updated_at
    FROM routes
    """)

    execute("""
    INSERT INTO endpoints (id, route_id, type, position, enabled, name, alias, status, schema, schema_options, node, started_at, stopped_at, lock_version, last_probe_at, last_failure_at, inserted_at, updated_at)
    SELECT
      d.id,
      d.route_id,
      'destination',
      ROW_NUMBER() OVER (PARTITION BY d.route_id ORDER BY d.inserted_at) - 1,
      d.enabled,
      d.name,
      d.alias,
      d.status,
      COALESCE(d.schema, 'SRT'),
      COALESCE(d.schema_options, '{}'),
      d.node,
      d.started_at,
      d.stopped_at,
      COALESCE(d.lock_version, 1),
      NULL,
      NULL,
      d.inserted_at,
      d.updated_at
    FROM destinations d
    """)

    drop_if_exists index(:destinations, [:route_id])
    drop_if_exists index(:destinations, [:enabled])
    drop_if_exists index(:destinations, [:status])
    drop_if_exists table(:destinations)

    alter table(:routes) do
      add :active_source_id, references(:endpoints, type: :binary_id, on_delete: :nilify_all)
    end

    execute("""
    UPDATE routes
    SET active_source_id = (
      SELECT e.id
      FROM endpoints e
      WHERE e.route_id = routes.id AND e.type = 'source' AND e.position = 0
      LIMIT 1
    )
    """)

    alter table(:routes) do
      remove :schema
      remove :schema_options
    end
  end

  def down do
    alter table(:routes) do
      add :schema, :string
      add :schema_options, :map
    end

    execute("""
    UPDATE routes
    SET schema = (
      SELECT e.schema
      FROM endpoints e
      WHERE e.route_id = routes.id AND e.type = 'source' AND e.position = 0
      LIMIT 1
    ),
    schema_options = (
      SELECT e.schema_options
      FROM endpoints e
      WHERE e.route_id = routes.id AND e.type = 'source' AND e.position = 0
      LIMIT 1
    )
    """)

    alter table(:routes) do
      remove :active_source_id
    end

    create table(:destinations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :route_id, references(:routes, type: :binary_id, on_delete: :delete_all), null: false
      add :enabled, :boolean, default: false
      add :name, :string
      add :alias, :string
      add :status, :string
      add :schema, :string
      add :schema_options, :map
      add :node, :string
      add :started_at, :utc_datetime
      add :stopped_at, :utc_datetime
      add :lock_version, :integer, default: 1
      timestamps(type: :utc_datetime)
    end

    create index(:destinations, [:route_id])
    create index(:destinations, [:enabled])
    create index(:destinations, [:status])

    execute("""
    INSERT INTO destinations (id, route_id, enabled, name, alias, status, schema, schema_options, node, started_at, stopped_at, lock_version, inserted_at, updated_at)
    SELECT
      id,
      route_id,
      enabled,
      name,
      alias,
      status,
      schema,
      schema_options,
      node,
      started_at,
      stopped_at,
      lock_version,
      inserted_at,
      updated_at
    FROM endpoints
    WHERE type = 'destination'
    """)

    drop_if_exists index(:endpoints, [:route_id, :type])
    drop_if_exists index(:endpoints, [:route_id])

    drop_if_exists index(:endpoints, [:route_id, :position, :type],
                     name: :endpoints_route_id_position_type_index
                   )

    drop_if_exists table(:endpoints)

    alter table(:routes) do
      remove :backup_config
      remove :last_switch_reason
      remove :last_switch_at
    end
  end
end

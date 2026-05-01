defmodule HydraSrt.Repo.Migrations.CreateSourcesAndMigrateFromRoutes do
  use Ecto.Migration

  def up do
    create table(:sources, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :route_id, references(:routes, type: :binary_id, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :enabled, :boolean, default: true, null: false
      add :name, :string
      add :schema, :string, null: false
      add :schema_options, :map, default: %{}, null: false
      add :status, :string
      add :last_probe_at, :utc_datetime_usec
      add :last_failure_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sources, [:route_id, :position])
    create index(:sources, [:route_id])

    execute("""
    INSERT INTO sources (id, route_id, position, enabled, name, schema, schema_options, inserted_at, updated_at)
    SELECT
      lower(hex(randomblob(4))) || '-' ||
      lower(hex(randomblob(2))) || '-' ||
      '4' || substr(lower(hex(randomblob(2))), 2) || '-' ||
      substr('89ab', abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))), 2) || '-' ||
      lower(hex(randomblob(6))),
      id,
      0,
      1,
      NULL,
      COALESCE(schema, 'SRT'),
      COALESCE(schema_options, '{}'),
      inserted_at,
      updated_at
    FROM routes
    """)

    alter table(:routes) do
      add :backup_config, :map, default: %{}, null: false
      add :active_source_id, references(:sources, type: :binary_id, on_delete: :nilify_all)
      add :last_switch_reason, :string
      add :last_switch_at, :utc_datetime_usec
    end

    execute("""
    UPDATE routes
    SET active_source_id = (
      SELECT s.id
      FROM sources s
      WHERE s.route_id = routes.id AND s.position = 0
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
      SELECT s.schema
      FROM sources s
      WHERE s.route_id = routes.id AND s.position = 0
      LIMIT 1
    ),
    schema_options = (
      SELECT s.schema_options
      FROM sources s
      WHERE s.route_id = routes.id AND s.position = 0
      LIMIT 1
    )
    """)

    alter table(:routes) do
      remove :backup_config
      remove :active_source_id
      remove :last_switch_reason
      remove :last_switch_at
    end

    drop_if_exists index(:sources, [:route_id])
    drop_if_exists index(:sources, [:route_id, :position])
    drop table(:sources)
  end
end

defmodule HydraSrt.Repo.Migrations.MergeSourcesAndDestinationsIntoEndpoints do
  use Ecto.Migration

  def up do
    alter table(:routes) do
      remove :active_source_id
    end

    drop_if_exists index(:sources, [:route_id])
    drop_if_exists index(:sources, [:route_id, :position])
    drop_if_exists index(:destinations, [:route_id])
    drop_if_exists index(:destinations, [:enabled])
    drop_if_exists index(:destinations, [:status])

    drop_if_exists table(:sources)
    drop_if_exists table(:destinations)

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
             name: :endpoints_route_id_position_type_index,
             where: "type = 'source'"
           )

    alter table(:routes) do
      add :active_source_id, references(:endpoints, type: :binary_id, on_delete: :nilify_all)
    end
  end

  def down do
    alter table(:routes) do
      remove :active_source_id
    end

    drop_if_exists index(:endpoints, [:route_id, :type])
    drop_if_exists index(:endpoints, [:route_id])

    drop_if_exists index(:endpoints, [:route_id, :position, :type],
                     name: :endpoints_route_id_position_type_index
                   )

    drop_if_exists table(:endpoints)

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

    alter table(:routes) do
      add :active_source_id, references(:sources, type: :binary_id, on_delete: :nilify_all)
    end
  end
end

defmodule HydraSrt.Repo.Migrations.ExtendDestinationsForRouteFkAndPayload do
  use Ecto.Migration

  def change do
    alter table(:destinations) do
      add :route_id, references(:routes, type: :binary_id, on_delete: :delete_all), null: false
      add :schema, :string
      add :schema_options, :map
      add :node, :string
      add :lock_version, :integer, default: 1, null: false
    end

    create index(:destinations, [:route_id])
    create index(:destinations, [:enabled])
    create index(:destinations, [:status])
  end
end

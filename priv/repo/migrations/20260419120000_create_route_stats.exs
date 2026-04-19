defmodule HydraSrt.Repo.Migrations.CreateRouteStats do
  use Ecto.Migration

  def change do
    create table(:route_stats, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :route_id, :string, null: false
      add :source_stream_id, :string
      add :stats, :map, null: false

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create index(:route_stats, [:inserted_at])
    create index(:route_stats, [:route_id, :inserted_at])
  end
end

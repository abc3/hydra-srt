defmodule HydraSrt.Repo.Migrations.CreateRoutes do
  use Ecto.Migration

  def change do
    create table(:routes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :enabled, :boolean, default: false, null: false
      add :name, :string
      add :alias, :string
      add :status, :string
      add :source, :map
      add :destinations, :map
      add :started_at, :utc_datetime
      add :stopped_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end
  end
end

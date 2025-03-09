defmodule HydraSrt.Repo.Migrations.CreateDestinations do
  use Ecto.Migration

  def change do
    create table(:destinations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :enabled, :boolean, default: false, null: false
      add :name, :string
      add :alias, :string
      add :status, :string
      add :started_at, :utc_datetime
      add :stopped_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end
  end
end

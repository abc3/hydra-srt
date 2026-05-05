defmodule HydraSrt.Repo.Migrations.CreateTagsTables do
  use Ecto.Migration

  def change do
    create table(:tags, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tags, [:name])

    create table(:route_tags, primary_key: false) do
      add :route_id, references(:routes, type: :binary_id, on_delete: :delete_all), null: false
      add :tag_id, references(:tags, type: :binary_id, on_delete: :delete_all), null: false
    end

    create unique_index(:route_tags, [:route_id, :tag_id])
  end
end

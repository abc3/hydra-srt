defmodule HydraSrt.Repo.Migrations.CreateTokens do
  use Ecto.Migration

  def change do
    create table(:tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :hash, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tokens, [:hash])
    create unique_index(:tokens, [:name])
  end
end

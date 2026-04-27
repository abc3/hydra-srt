defmodule HydraSrt.Repo.Migrations.CreateInterfaces do
  use Ecto.Migration

  def change do
    create table(:interfaces, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string
      add :sys_name, :string, null: false
      add :ip, :string, null: false
      add :enabled, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:interfaces, [:sys_name])
  end
end

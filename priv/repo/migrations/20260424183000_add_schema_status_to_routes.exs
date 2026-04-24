defmodule HydraSrt.Repo.Migrations.AddSchemaStatusToRoutes do
  use Ecto.Migration

  def change do
    alter table(:routes) do
      add :schema_status, :string
    end

    create index(:routes, [:schema_status])
  end
end

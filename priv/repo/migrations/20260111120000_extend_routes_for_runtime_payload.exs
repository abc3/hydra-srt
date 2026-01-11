defmodule HydraSrt.Repo.Migrations.ExtendRoutesForRuntimePayload do
  use Ecto.Migration

  def change do
    alter table(:routes) do
      add :export_stats, :boolean, default: false, null: false
      add :schema, :string
      add :schema_options, :map
      add :node, :string
      add :gst_debug, :string
      add :lock_version, :integer, default: 1, null: false
    end

    create index(:routes, [:enabled])
    create index(:routes, [:status])
  end
end

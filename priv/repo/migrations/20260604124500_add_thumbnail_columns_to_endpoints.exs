defmodule HydraSrt.Repo.Migrations.AddThumbnailColumnsToEndpoints do
  use Ecto.Migration

  def up do
    alter table(:endpoints) do
      add :thumbnail_enabled, :boolean, default: false, null: false
      add :thumbnail_interval_ms, :integer, default: 5000, null: false
      add :thumbnail_capture_policy, :string, default: "running", null: false
    end
  end

  def down do
    alter table(:endpoints) do
      remove :thumbnail_capture_policy
      remove :thumbnail_interval_ms
      remove :thumbnail_enabled
    end
  end
end

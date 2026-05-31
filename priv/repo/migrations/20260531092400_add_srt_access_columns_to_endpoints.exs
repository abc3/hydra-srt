defmodule HydraSrt.Repo.Migrations.AddSrtAccessColumnsToEndpoints do
  use Ecto.Migration

  def up do
    alter table(:endpoints) do
      add :allowed_list, :text, default: "[]", null: false
      add :denied_list, :text, default: "[]", null: false
      add :limit_access, :boolean, default: false, null: false
    end
  end

  def down do
    alter table(:endpoints) do
      remove :limit_access
      remove :denied_list
      remove :allowed_list
    end
  end
end

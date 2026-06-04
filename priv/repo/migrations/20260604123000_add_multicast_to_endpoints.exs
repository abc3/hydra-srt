defmodule HydraSrt.Repo.Migrations.AddMulticastToEndpoints do
  use Ecto.Migration

  def up do
    alter table(:endpoints) do
      add :multicast, :boolean, default: false, null: false
    end
  end

  def down do
    alter table(:endpoints) do
      remove :multicast
    end
  end
end

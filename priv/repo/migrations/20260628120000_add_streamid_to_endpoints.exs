defmodule HydraSrt.Repo.Migrations.AddStreamidToEndpoints do
  use Ecto.Migration

  def up do
    alter table(:endpoints) do
      add :streamid, :string
    end
  end

  def down do
    alter table(:endpoints) do
      remove :streamid
    end
  end
end

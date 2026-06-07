defmodule HydraSrt.Repo.Migrations.AddRtmpFieldsToEndpoints do
  use Ecto.Migration

  def change do
    alter table(:endpoints) do
      add :path, :string
      add :location, :string
    end
  end
end

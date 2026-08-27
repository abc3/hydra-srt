defmodule HydraSrt.Repo.Migrations.AddProgramNumberToEndpoints do
  use Ecto.Migration

  @moduledoc "Adds the optional MPEG-TS program number to endpoints."

  def up do
    alter table(:endpoints) do
      add :program_number, :integer
    end
  end

  def down do
    alter table(:endpoints) do
      remove :program_number
    end
  end
end

defmodule HydraSrt.Repo.Migrations.AddSrtListenerControls do
  use Ecto.Migration

  def up do
    alter table(:endpoints) do
      add :max_callers, :integer
      add :streamid_match_mode, :string
    end

    create table(:caller_labels, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :address, :string, null: false
      add :label, :string, null: false
      add :note, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:caller_labels, [:address])
  end

  def down do
    drop_if_exists index(:caller_labels, [:address])
    drop table(:caller_labels)

    alter table(:endpoints) do
      remove :streamid_match_mode
      remove :max_callers
    end
  end
end

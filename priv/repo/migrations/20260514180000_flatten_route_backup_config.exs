defmodule HydraSrt.Repo.Migrations.FlattenRouteBackupConfig do
  use Ecto.Migration

  def up do
    alter table(:routes) do
      add :backup_mode, :string, default: "passive", null: false
      add :backup_switch_after_ms, :integer, default: 3000, null: false
      add :backup_cooldown_ms, :integer, default: 10000, null: false
      add :backup_primary_stable_ms, :integer, default: 15000, null: false
      add :backup_probe_interval_ms, :integer, default: 5000, null: false
    end

    execute("""
    UPDATE routes
    SET
      backup_mode = COALESCE(
        NULLIF(lower(trim(json_extract(backup_config, '$.mode'))), ''),
        'passive'
      ),
      backup_switch_after_ms = COALESCE(
        CAST(json_extract(backup_config, '$.switch_after_ms') AS INTEGER),
        3000
      ),
      backup_cooldown_ms = COALESCE(
        CAST(json_extract(backup_config, '$.cooldown_ms') AS INTEGER),
        10000
      ),
      backup_primary_stable_ms = COALESCE(
        CAST(json_extract(backup_config, '$.primary_stable_ms') AS INTEGER),
        15000
      ),
      backup_probe_interval_ms = COALESCE(
        CAST(json_extract(backup_config, '$.probe_interval_ms') AS INTEGER),
        5000
      )
    """)

    alter table(:routes) do
      remove :backup_config
    end
  end

  def down do
    alter table(:routes) do
      add :backup_config, :map, default: %{}, null: false
    end

    execute("""
    UPDATE routes
    SET backup_config = json_object(
      'mode', backup_mode,
      'switch_after_ms', backup_switch_after_ms,
      'cooldown_ms', backup_cooldown_ms,
      'primary_stable_ms', backup_primary_stable_ms,
      'probe_interval_ms', backup_probe_interval_ms
    )
    """)

    alter table(:routes) do
      remove :backup_mode
      remove :backup_switch_after_ms
      remove :backup_cooldown_ms
      remove :backup_primary_stable_ms
      remove :backup_probe_interval_ms
    end
  end
end

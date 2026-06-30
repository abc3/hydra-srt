defmodule HydraSrt.BackupTest do
  use ExUnit.Case, async: false

  alias HydraSrt.Backup

  test "ensure_repo_db_path allows paths under the repo database directory" do
    db_path = Backup.repo_database_path()
    dir = Backup.repo_database_dir()

    assert :ok = Backup.ensure_repo_db_path(dir)
    assert :ok = Backup.ensure_repo_db_path(db_path)
    assert :ok = Backup.ensure_repo_db_path(Path.join(dir, "hydra_srt_restore_1.db"))
    assert :ok = Backup.ensure_repo_db_path(db_path <> ".bak")
    assert :ok = Backup.ensure_repo_db_path(db_path <> "-wal")
    assert :ok = Backup.ensure_repo_db_path(db_path <> "-shm")
  end

  test "ensure_repo_db_path rejects paths outside the repo database directory" do
    outside = Path.expand("/hydra_backup_outside_#{System.unique_integer([:positive])}.db")

    assert {:error, :invalid_path} = Backup.ensure_repo_db_path(outside)
    assert {:error, :invalid_path} = Backup.ensure_repo_db_path("/etc/passwd")
    assert {:error, :invalid_path} = Backup.ensure_repo_db_path(nil)
  end

  test "safe_rm refuses to delete files outside the repo database directory" do
    outside = Path.expand("/hydra_backup_outside_#{System.unique_integer([:positive])}.db")

    assert {:error, :invalid_path} = Backup.safe_rm(outside)
  end

  test "swap_db_files rejects paths outside the repo database directory" do
    db_path = Backup.repo_database_path()
    dir = Backup.repo_database_dir()
    tmp_path = Path.join(dir, "hydra_srt_restore_#{System.unique_integer([:positive])}.db")
    bak_path = db_path <> ".bak"
    outside = Path.expand("/hydra_backup_outside_#{System.unique_integer([:positive])}.db")

    assert {:error, :invalid_path} = Backup.swap_db_files(outside, tmp_path, bak_path)
    assert {:error, :invalid_path} = Backup.swap_db_files(db_path, outside, bak_path)
    assert {:error, :invalid_path} = Backup.swap_db_files(db_path, tmp_path, outside)
  end

  test "swap_db_files restores the original file when the replacement is missing" do
    dir = Backup.repo_database_dir()
    suffix = System.unique_integer([:positive])
    db_path = Path.join(dir, "swap_test_#{suffix}.db")
    tmp_path = Path.join(dir, "missing_restore_#{suffix}.db")
    bak_path = db_path <> ".bak"

    on_exit(fn ->
      Backup.safe_rm(db_path)
      Backup.safe_rm(tmp_path)
      Backup.safe_rm(bak_path)
    end)

    assert :ok = File.write(db_path, "original")

    assert {:error, {:swap_failed_rolled_back, :enoent}} =
             Backup.swap_db_files(db_path, tmp_path, bak_path)

    assert {:ok, "original"} = File.read(db_path)
    refute File.exists?(bak_path)
  end

  test "restore_backup_file preserves the live database when the backup is missing" do
    dir = Backup.repo_database_dir()
    suffix = System.unique_integer([:positive])
    db_path = Path.join(dir, "rollback_test_#{suffix}.db")
    bak_path = db_path <> ".bak"

    on_exit(fn ->
      Backup.safe_rm(db_path)
      Backup.safe_rm(bak_path)
    end)

    assert :ok = File.write(db_path, "live database")
    assert {:error, :backup_missing} = Backup.restore_backup_file(db_path, bak_path)
    assert {:ok, "live database"} = File.read(db_path)
  end

  test "schema compatibility requires the same migration versions" do
    db_path = Backup.repo_database_path()
    assert :ok = Backup.validate_schema_compatibility(db_path, db_path)

    invalid_path =
      Path.join(
        Backup.repo_database_dir(),
        "invalid_schema_#{System.unique_integer([:positive])}.db"
      )

    on_exit(fn -> Backup.safe_rm(invalid_path) end)
    assert :ok = File.write(invalid_path, "")
    assert {:error, _reason} = Backup.validate_schema_compatibility(db_path, invalid_path)
  end

  test "schema_versions closes the connection when statement preparation fails" do
    parent = self()

    :meck.new(Exqlite.Sqlite3, [:passthrough])
    :meck.expect(Exqlite.Sqlite3, :open, fn _path, _options -> {:ok, :connection} end)
    :meck.expect(Exqlite.Sqlite3, :prepare, fn :connection, _sql -> {:error, :invalid_db} end)

    :meck.expect(Exqlite.Sqlite3, :close, fn :connection ->
      send(parent, :connection_closed)
      :ok
    end)

    on_exit(fn -> :meck.unload() end)

    assert {:error, :invalid_db} = Backup.schema_versions("invalid.db")
    assert_receive :connection_closed
  end

  test "removes the uploaded database when restore fails after validation" do
    restore_pattern = Path.join(Backup.repo_database_dir(), "hydra_srt_restore_*.db")
    files_before = restore_pattern |> Path.wildcard() |> MapSet.new()
    assert {:ok, snapshot} = Backup.backup_db_file()

    :meck.new(HydraSrt.RouteBackup, [:passthrough])
    :meck.expect(HydraSrt.RouteBackup, :stop_routes, fn -> {:error, :stop_failed} end)

    on_exit(fn -> :meck.unload() end)

    assert {:error, :stop_failed} = Backup.restore_db_file(snapshot)
    assert restore_pattern |> Path.wildcard() |> MapSet.new() == files_before
  end
end

defmodule HydraSrt.BackupTest do
  use ExUnit.Case, async: true

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
end

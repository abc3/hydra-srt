defmodule HydraSrt.Backup do
  @moduledoc false

  require Logger

  @doc """
  Returns a consistent snapshot of the SQLite database file as a binary.

  This uses SQLite's online serialization (safe with WAL) instead of reading the file from disk.
  """
  def backup_db_file do
    HydraSrt.BackupLock.run(fn ->
      db_path = repo_database_path()

      case Exqlite.Sqlite3.open(db_path, mode: :readonly) do
        {:ok, conn} ->
          result = Exqlite.Sqlite3.serialize(conn, "main")
          _ = Exqlite.Sqlite3.close(conn)
          result

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc """
  Restores the SQLite database from a `.db` snapshot binary.

  Strategy:
  - Write uploaded bytes to a temp file in the same directory
  - Validate via `PRAGMA integrity_check`
  - Stop `HydraSrt.Repo`, atomically swap DB file, remove `-wal/-shm`, restart `HydraSrt.Repo`
  """
  # sobelow_skip ["Traversal.FileModule"]
  def restore_db_file(binary) when is_binary(binary) do
    HydraSrt.BackupLock.run(fn ->
      db_path = repo_database_path()
      dir = repo_database_dir()

      tmp_path =
        Path.join(dir, "hydra_srt_restore_#{System.unique_integer([:positive])}.db")

      bak_path = db_path <> ".bak"

      try do
        with :ok <- ensure_repo_db_path(dir),
             :ok <- ensure_repo_db_path(tmp_path),
             :ok <- ensure_repo_db_path(bak_path),
             :ok <- File.mkdir_p(dir),
             :ok <- File.write(tmp_path, binary),
             :ok <- validate_db_file(tmp_path),
             :ok <- validate_schema_compatibility(db_path, tmp_path) do
          restore_validated_db(db_path, tmp_path, bak_path)
        end
      after
        _ = safe_rm(tmp_path)
      end
    end)
  end

  @doc false
  def restore_db_file(_), do: {:error, :invalid_backup}

  @doc false
  def repo_database_path do
    case HydraSrt.Repo.config()[:database] do
      path when is_binary(path) -> path
      other -> raise "HydraSrt.Repo database path is not configured: #{inspect(other)}"
    end
  end

  def repo_database_dir do
    repo_database_path() |> Path.dirname() |> Path.expand()
  end

  def ensure_repo_db_path(path) when is_binary(path) do
    expanded = Path.expand(path)
    root = repo_database_dir()

    if expanded == root or String.starts_with?(expanded, root <> "/") do
      :ok
    else
      {:error, :invalid_path}
    end
  end

  def ensure_repo_db_path(_), do: {:error, :invalid_path}

  @doc false
  def validate_db_file(db_path) when is_binary(db_path) do
    case Exqlite.Sqlite3.open(db_path, mode: :readonly) do
      {:ok, conn} ->
        result =
          case Exqlite.Sqlite3.prepare(conn, "PRAGMA integrity_check;") do
            {:ok, stmt} ->
              step_result = Exqlite.Sqlite3.step(conn, stmt)
              _ = Exqlite.Sqlite3.release(conn, stmt)
              step_result

            {:error, reason} ->
              {:error, reason}
          end

        _ = Exqlite.Sqlite3.close(conn)

        case result do
          {:row, ["ok"]} -> :ok
          {:row, [message]} -> {:error, {:integrity_check_failed, message}}
          :done -> {:error, :integrity_check_no_result}
          :busy -> {:error, :integrity_check_busy}
          {:error, reason} -> {:error, reason}
          other -> {:error, other}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec validate_schema_compatibility(binary(), binary()) :: :ok | {:error, term()}
  def validate_schema_compatibility(current_path, restore_path) do
    with {:ok, current_versions} <- schema_versions(current_path),
         {:ok, restore_versions} <- schema_versions(restore_path) do
      if current_versions == restore_versions do
        :ok
      else
        {:error, :incompatible_schema}
      end
    end
  end

  @spec schema_versions(binary()) :: {:ok, [integer()]} | {:error, term()}
  def schema_versions(db_path) do
    with {:ok, conn} <- Exqlite.Sqlite3.open(db_path, mode: :readonly) do
      result =
        case Exqlite.Sqlite3.prepare(
               conn,
               "SELECT version FROM schema_migrations ORDER BY version"
             ) do
          {:ok, stmt} ->
            result = collect_schema_versions(conn, stmt, [])
            _ = Exqlite.Sqlite3.release(conn, stmt)
            result

          {:error, reason} ->
            {:error, reason}
        end

      _ = Exqlite.Sqlite3.close(conn)
      result
    end
  end

  @spec collect_schema_versions(term(), term(), [integer()]) ::
          {:ok, [integer()]} | {:error, term()}
  def collect_schema_versions(conn, stmt, versions) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, [version]} -> collect_schema_versions(conn, stmt, [version | versions])
      :done -> {:ok, Enum.reverse(versions)}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  @spec restore_validated_db(binary(), binary(), binary()) :: :ok | {:error, term()}
  def restore_validated_db(db_path, tmp_path, bak_path) do
    with :ok <- HydraSrt.RouteBackup.stop_routes() do
      case stop_repo() do
        :ok ->
          replace_stopped_repo(db_path, tmp_path, bak_path)

        {:error, reason} ->
          _ = HydraSrt.RouteBackup.start_enabled_routes()
          {:error, reason}
      end
    end
  end

  @spec replace_stopped_repo(binary(), binary(), binary()) :: :ok | {:error, term()}
  def replace_stopped_repo(db_path, tmp_path, bak_path) do
    with :ok <- swap_db_files(db_path, tmp_path, bak_path),
         :ok <- cleanup_wal_shm(db_path),
         :ok <- start_repo(),
         :ok <- HydraSrt.RouteBackup.start_enabled_routes() do
      _ = safe_rm(bak_path)
      :ok
    else
      {:error, {:swap_failed_rolled_back, reason}} ->
        recover_after_failed_swap(reason)

      {:error, reason} ->
        rollback_restore(db_path, tmp_path, bak_path, reason)
    end
  end

  @spec recover_after_failed_swap(term()) :: {:error, term()}
  def recover_after_failed_swap(reason) do
    with :ok <- start_repo(),
         :ok <- HydraSrt.RouteBackup.start_enabled_routes() do
      {:error, reason}
    else
      recovery_error -> {:error, {:swap_failed_and_recovery_incomplete, reason, recovery_error}}
    end
  end

  @spec rollback_restore(binary(), binary(), binary(), term()) :: {:error, term()}
  def rollback_restore(db_path, tmp_path, bak_path, reason) do
    if Process.whereis(HydraSrt.Repo) do
      _ = HydraSrt.RouteBackup.stop_routes()
    end

    _ = stop_repo()
    rollback_result = restore_backup_file(db_path, bak_path)

    _ = safe_rm(tmp_path)
    _ = cleanup_wal_shm(db_path)
    restart_result = start_repo()

    routes_result =
      if restart_result == :ok, do: HydraSrt.RouteBackup.start_enabled_routes(), else: :ok

    case {rollback_result, restart_result, routes_result} do
      {:ok, :ok, :ok} -> {:error, reason}
      results -> {:error, {:restore_failed_and_rollback_incomplete, reason, results}}
    end
  end

  @spec restore_backup_file(binary(), binary()) :: :ok | {:error, term()}
  def restore_backup_file(db_path, bak_path) do
    if File.exists?(bak_path) do
      with :ok <- safe_rm(db_path) do
        File.rename(bak_path, db_path)
      end
    else
      {:error, :backup_missing}
    end
  end

  @doc false
  def stop_repo do
    case Process.whereis(HydraSrt.Repo) do
      pid when is_pid(pid) ->
        case Supervisor.terminate_child(HydraSrt.Supervisor, HydraSrt.Repo) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      _ ->
        :ok
    end
  end

  @doc false
  def start_repo do
    case Supervisor.restart_child(HydraSrt.Supervisor, HydraSrt.Repo) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def swap_db_files(db_path, tmp_path, bak_path)
      when is_binary(db_path) and is_binary(tmp_path) and is_binary(bak_path) do
    with :ok <- ensure_repo_db_path(db_path),
         :ok <- ensure_repo_db_path(tmp_path),
         :ok <- ensure_repo_db_path(bak_path) do
      _ = safe_rm(bak_path)

      case File.exists?(db_path) do
        true ->
          case File.rename(db_path, bak_path) do
            :ok -> do_swap(tmp_path, db_path, bak_path)
            {:error, reason} -> {:error, reason}
          end

        false ->
          do_swap(tmp_path, db_path, bak_path)
      end
    end
  end

  @doc false
  def do_swap(tmp_path, db_path, bak_path) do
    case File.rename(tmp_path, db_path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to swap DB file: #{inspect(reason)}")

        case File.rename(bak_path, db_path) do
          :ok -> {:error, {:swap_failed_rolled_back, reason}}
          {:error, rollback_reason} -> {:error, {:swap_failed, reason, rollback_reason}}
        end
    end
  end

  @doc false
  def cleanup_wal_shm(db_path) when is_binary(db_path) do
    _ = safe_rm(db_path <> "-wal")
    _ = safe_rm(db_path <> "-shm")
    :ok
  end

  @doc false
  # sobelow_skip ["Traversal.FileModule"]
  def safe_rm(path) when is_binary(path) do
    with :ok <- ensure_repo_db_path(path) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        other -> other
      end
    end
  end
end

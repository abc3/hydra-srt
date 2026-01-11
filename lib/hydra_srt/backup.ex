defmodule HydraSrt.Backup do
  @moduledoc false

  require Logger

  @doc """
  Returns a consistent snapshot of the SQLite database file as a binary.

  This uses SQLite's online serialization (safe with WAL) instead of reading the file from disk.
  """
  def backup_db_file do
    :global.trans({__MODULE__, :backup_restore}, fn ->
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
  def restore_db_file(binary) when is_binary(binary) do
    :global.trans({__MODULE__, :backup_restore}, fn ->
      db_path = repo_database_path()
      dir = Path.dirname(db_path)
      tmp_path = Path.join(dir, "hydra_srt_restore_#{System.unique_integer([:positive])}.db")
      bak_path = db_path <> ".bak"

      with :ok <- File.mkdir_p(dir),
           :ok <- File.write(tmp_path, binary),
           :ok <- validate_db_file(tmp_path),
           :ok <- stop_repo(),
           :ok <- swap_db_files(db_path, tmp_path, bak_path),
           :ok <- cleanup_wal_shm(db_path),
           :ok <- start_repo() do
        :ok
      else
        {:error, reason} ->
          _ = safe_rm(tmp_path)
          _ = safe_rm(bak_path)
          {:error, reason}

        other ->
          _ = safe_rm(tmp_path)
          _ = safe_rm(bak_path)
          {:error, other}
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
      other -> {:error, other}
    end
  end

  @doc false
  def swap_db_files(db_path, tmp_path, bak_path)
      when is_binary(db_path) and is_binary(tmp_path) and is_binary(bak_path) do
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

  @doc false
  def do_swap(tmp_path, db_path, bak_path) do
    case File.rename(tmp_path, db_path) do
      :ok ->
        _ = safe_rm(bak_path)
        :ok

      {:error, reason} ->
        Logger.error("Failed to swap DB file: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc false
  def cleanup_wal_shm(db_path) when is_binary(db_path) do
    _ = safe_rm(db_path <> "-wal")
    _ = safe_rm(db_path <> "-shm")
    :ok
  end

  @doc false
  def safe_rm(path) when is_binary(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      other -> other
    end
  end
end

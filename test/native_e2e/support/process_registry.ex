defmodule HydraSrt.E2E.Native.ProcessRegistry do
  @moduledoc false

  @table :hydra_rs_native_e2e_processes

  def ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          _tid =
            :ets.new(@table, [
              :named_table,
              :set,
              :public,
              read_concurrency: true,
              write_concurrency: true
            ])

          :ok
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  def register!(key, meta) when is_map(meta) do
    :ok = ensure_table!()
    true = :ets.insert(@table, {key, meta})
    :ok
  end

  def unregister!(key) do
    :ok = ensure_table!()
    _ = :ets.delete(@table, key)
    :ok
  end

  def list do
    :ok = ensure_table!()
    :ets.tab2list(@table)
  end

  def cleanup_all! do
    :ok = ensure_table!()

    list()
    |> Enum.each(fn {key, meta} ->
      cleanup_entry(key, meta)
    end)

    :ok
  end

  def cleanup_entry(key, meta) do
    os_pid = Map.get(meta, :os_pid)
    port = Map.get(meta, :port)

    if is_port(port) do
      try do
        Port.close(port)
      rescue
        _ -> :ok
      end
    end

    if is_integer(os_pid) and process_alive?(os_pid) do
      _ = System.cmd("kill", ["-15", Integer.to_string(os_pid)], stderr_to_stdout: true)
      wait_for_exit(os_pid, 300)
    end

    if is_integer(os_pid) and process_alive?(os_pid) do
      _ = System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
      wait_for_exit(os_pid, 300)
    end

    unregister!(key)
    :ok
  end

  def process_alive?(os_pid) when is_integer(os_pid) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_out, 0} -> true
      _ -> false
    end
  end

  defp wait_for_exit(os_pid, timeout_ms) do
    start_ms = System.monotonic_time(:millisecond)
    do_wait_for_exit(os_pid, start_ms, timeout_ms)
  end

  defp do_wait_for_exit(os_pid, start_ms, timeout_ms) do
    if not process_alive?(os_pid) do
      :ok
    else
      now = System.monotonic_time(:millisecond)

      if now - start_ms > timeout_ms do
        :timeout
      else
        Process.sleep(25)
        do_wait_for_exit(os_pid, start_ms, timeout_ms)
      end
    end
  end
end

defmodule HydraSrt.Helpers do
  @moduledoc false

  @doc """
  Sets the maximum heap size for the current process. The `max_heap_size` parameter is in megabytes.

  ## Parameters

  - `max_heap_size`: The maximum heap size in megabytes.
  """
  @spec set_max_heap_size(pos_integer()) :: map()
  def set_max_heap_size(max_heap_size) do
    max_heap_words = div(max_heap_size * 1024 * 1024, :erlang.system_info(:wordsize))
    Process.flag(:max_heap_size, %{size: max_heap_words})
  end

  def sys_kill(process_id) do
    System.cmd("kill", ["-9", "#{process_id}"])
  end

  def wait_for_process_exit(process_id, timeout_ms \\ 500)

  def wait_for_process_exit(process_id, timeout_ms) when is_integer(process_id) do
    process_id
    |> Integer.to_string()
    |> wait_for_process_exit(timeout_ms)
  end

  def wait_for_process_exit(process_id, timeout_ms) when is_binary(process_id) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_process_exit(process_id, deadline)
  end

  defp do_wait_for_process_exit(process_id, deadline) do
    case System.cmd("kill", ["-0", process_id], stderr_to_stdout: true) do
      {_output, 0} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(25)
          do_wait_for_process_exit(process_id, deadline)
        end

      _not_alive ->
        :ok
    end
  end
end

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

  @spec get_by_string_key(map(), String.t(), term()) :: term()
  def get_by_string_key(map, key, default \\ nil) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        case existing_atom_key(map, key) do
          {:ok, value} -> value
          :error -> default
        end
    end
  end

  @spec get_by_string_key_or(map(), String.t(), term()) :: term()
  def get_by_string_key_or(map, key, default \\ nil) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      case existing_atom_key(map, key) do
        {:ok, value} -> value
        :error -> default
      end
  end

  @spec has_string_key?(map(), String.t()) :: boolean()
  def has_string_key?(map, key) when is_map(map) and is_binary(key) do
    Map.has_key?(map, key) or match?({:ok, _}, existing_atom_key(map, key))
  end

  @doc false
  def existing_atom_key(map, key) when is_map(map) and is_binary(key) do
    try do
      Map.fetch(map, String.to_existing_atom(key))
    rescue
      ArgumentError -> :error
    end
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

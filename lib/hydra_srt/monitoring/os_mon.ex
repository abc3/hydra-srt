defmodule HydraSrt.Monitoring.OsMon do
  @moduledoc false

  require Logger

  @spec ram_usage() :: float()
  def ram_usage do
    mem = :memsup.get_system_memory_data()
    100 - mem[:free_memory] / mem[:total_memory] * 100
  end

  @spec cpu_la() :: %{avg1: float(), avg5: float(), avg15: float()}
  def cpu_la do
    %{
      avg1: :cpu_sup.avg1() / 256,
      avg5: :cpu_sup.avg5() / 256,
      avg15: :cpu_sup.avg15() / 256
    }
  end

  @spec cpu_util() :: float() | {:error, term()}
  def cpu_util do
    :cpu_sup.util()
  end

  @spec swap_usage() :: float() | nil
  def swap_usage do
    mem = :memsup.get_system_memory_data()

    with total_swap when is_integer(total_swap) <- Keyword.get(mem, :total_swap),
         free_swap when is_integer(free_swap) <- Keyword.get(mem, :free_swap) do
      100 - free_swap / total_swap * 100
    else
      _ -> nil
    end
  end

  @doc """
  Get all system stats in a single call
  """
  @spec get_all_stats() :: %{
          cpu: float() | {:error, term()},
          ram: float(),
          swap: float() | nil,
          cpu_la: %{avg1: float(), avg5: float(), avg15: float()}
        }
  def get_all_stats do
    %{
      cpu: cpu_util(),
      ram: ram_usage(),
      swap: swap_usage(),
      cpu_la: cpu_la()
    }
  end
end

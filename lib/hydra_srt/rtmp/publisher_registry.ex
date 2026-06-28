defmodule HydraSrt.Rtmp.PublisherRegistry do
  @moduledoc """
  Tracks the single active RTMP publisher per normalized path.

  Enforces publish exclusivity: only one publisher may publish to a given path at
  a time. Backed by a `Registry` with `:unique` keys, so entries auto-clean when
  the publisher process dies (DOWN). The publisher pid is the registry value.
  """

  @registry HydraSrt.Rtmp.PublisherRegistry

  @spec registry() :: atom()
  def registry, do: @registry

  @spec register(String.t(), pid()) :: :ok | {:error, {:conflict, pid()}}
  def register(path, pid) when is_binary(path) and path != "" and is_pid(pid) do
    case Registry.register(@registry, path, pid) do
      {:ok, _owner_pid} -> :ok
      {:error, {:already_registered, owner_pid}} -> {:error, {:conflict, owner_pid}}
    end
  end

  @spec unregister(String.t()) :: :ok
  def unregister(path) when is_binary(path) do
    Registry.unregister(@registry, path)
  end

  @spec active?(String.t()) :: boolean()
  def active?(path) when is_binary(path) do
    case Registry.lookup(@registry, path) do
      [{pid, _}] when is_pid(pid) -> true
      _ -> false
    end
  end

  @spec owner(String.t()) :: pid() | nil
  def owner(path) when is_binary(path) do
    case Registry.lookup(@registry, path) do
      [{pid, _}] when is_pid(pid) -> pid
      _ -> nil
    end
  end
end

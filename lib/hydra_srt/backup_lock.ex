defmodule HydraSrt.BackupLock do
  @moduledoc false

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec run((-> result)) :: result when result: term()
  def run(operation) when is_function(operation, 0) do
    GenServer.call(__MODULE__, {:run, operation}, :infinity)
  end

  @impl true
  @spec init(:ok) :: {:ok, :ok}
  def init(:ok), do: {:ok, :ok}

  @impl true
  @spec handle_call({:run, (-> term())}, GenServer.from(), :ok) :: {:reply, term(), :ok}
  def handle_call({:run, operation}, _from, :ok) do
    {:reply, operation.(), :ok}
  end
end

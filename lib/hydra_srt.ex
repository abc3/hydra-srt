defmodule HydraSrt do
  @moduledoc false
  require Logger
  alias HydraSrt.Db

  @spec start_route(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_route(id) do
    DynamicSupervisor.start_child(
      {:via, PartitionSupervisor, {HydraSrt.DynamicSupervisor, id}},
      {HydraSrt.RoutesSupervisor, %{id: id}}
    )
  end

  @spec get_route(String.t()) :: {:ok, pid()} | {:error, term()}
  def get_route(id) do
    case :syn.lookup(:routes, id) do
      {pid, _} when is_pid(pid) -> {:ok, pid}
      :undefined -> {:error, :not_found}
    end
  end

  @spec stop_route(String.t()) :: :ok | {:error, term()}
  def stop_route(id) do
    case get_route(id) do
      {:ok, pid} ->
        Supervisor.stop(pid, :normal)

      other ->
        HydraSrt.set_route_status(id, "stopped")
        other
    end
  end

  @spec restart_route(String.t()) :: {:ok, term()} | {:error, term()}
  def restart_route(id) do
    case stop_route(id) do
      {:error, reason} ->
        Logger.warning("Attempt to restart route #{id}, but: #{inspect(reason)}")

      _ ->
        nil
    end

    with {:ok, _pid} <- start_route(id) do
      {:ok, :restarted}
    end
  end

  @spec set_route_status(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def set_route_status(id, status) do
    with {:ok, route} <- Db.update_route(id, route_runtime_status_attrs(status)) do
      {:ok, route}
    end
  end

  defp route_runtime_status_attrs(status) when is_binary(status) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case String.downcase(status) do
      "started" ->
        %{
          "status" => status,
          "started_at" => now,
          "stopped_at" => nil
        }

      "stopped" ->
        %{
          "status" => status,
          "stopped_at" => now
        }

      _ ->
        %{"status" => status}
    end
  end
end

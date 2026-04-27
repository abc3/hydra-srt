defmodule HydraSrtWeb.InterfaceController do
  use HydraSrtWeb, :controller

  alias HydraSrt.Db
  alias HydraSrt.SystemInterfaces

  action_fallback HydraSrtWeb.FallbackController

  def index(conn, _params) do
    with {:ok, interfaces} <- Db.get_all_interfaces() do
      data(conn, interfaces)
    end
  end

  def create(conn, %{"interface" => interface_params}) do
    with {:ok, interface} <- Db.create_interface(interface_params) do
      conn
      |> put_status(:created)
      |> data(interface)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, interface} <- Db.get_interface(id) do
      data(conn, interface)
    end
  end

  def update(conn, %{"id" => id, "interface" => interface_params}) do
    with {:ok, interface} <- Db.update_interface(id, interface_params) do
      data(conn, interface)
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- Db.delete_interface(id) do
      send_resp(conn, :no_content, "")
    end
  end

  def system(conn, _params) do
    with {:ok, interfaces} <- SystemInterfaces.discover() do
      data(conn, interfaces)
    else
      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to read system interfaces: #{inspect(reason)}"})
    end
  end

  def system_raw(conn, _params) do
    with {:ok, raw_output} <- SystemInterfaces.discover_raw() do
      data(conn, %{"raw" => raw_output})
    else
      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to read raw ifconfig output: #{inspect(reason)}"})
    end
  end

  @doc false
  def data(conn, payload), do: json(conn, %{data: payload})
end

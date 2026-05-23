defmodule HydraSrtWeb.InterfaceController do
  use HydraSrtWeb, :controller

  alias HydraSrt.Interfaces

  action_fallback HydraSrtWeb.FallbackController

  def index(conn, _params) do
    with {:ok, interfaces} <- Interfaces.list() do
      data(conn, interfaces)
    end
  end

  def create(conn, %{"interface" => interface_params}) do
    with {:ok, interface} <- Interfaces.create(interface_params) do
      conn
      |> put_status(:created)
      |> data(interface)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, interface} <- Interfaces.get(id) do
      data(conn, interface)
    end
  end

  def update(conn, %{"id" => id, "interface" => interface_params}) do
    with {:ok, interface} <- Interfaces.update(id, interface_params) do
      data(conn, interface)
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- Interfaces.delete(id) do
      send_resp(conn, :no_content, "")
    end
  end

  def system(conn, _params) do
    case Interfaces.list_system() do
      {:ok, interfaces} ->
        data(conn, interfaces)

      {:error, message} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: message})
    end
  end

  def system_raw(conn, _params) do
    case Interfaces.system_raw() do
      {:ok, raw_output} ->
        data(conn, %{"raw" => raw_output})

      {:error, message} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: message})
    end
  end

  @doc false
  def data(conn, payload), do: json(conn, %{data: payload})
end

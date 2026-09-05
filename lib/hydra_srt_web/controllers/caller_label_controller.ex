defmodule HydraSrtWeb.CallerLabelController do
  use HydraSrtWeb, :controller

  alias HydraSrt.CallerLabels

  action_fallback HydraSrtWeb.FallbackController

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params), do: data(conn, Enum.map(CallerLabels.list(), &serialize/1))

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t() | {:error, term()}
  def create(conn, params) do
    with {:ok, label} <- CallerLabels.create(label_params(params)) do
      conn
      |> put_status(:created)
      |> data(serialize(label))
    end
  end

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t() | {:error, term()}
  def update(conn, %{"id" => id} = params) do
    with {:ok, label} <- CallerLabels.update(id, label_params(params)) do
      data(conn, serialize(label))
    end
  end

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t() | {:error, term()}
  def delete(conn, %{"id" => id}) do
    with {:ok, _label} <- CallerLabels.delete(id) do
      send_resp(conn, :no_content, "")
    end
  end

  @spec label_params(map()) :: map()
  def label_params(%{"caller_label" => params}) when is_map(params), do: params

  def label_params(params) when is_map(params) do
    Map.take(params, ["address", "label", "note"])
  end

  @spec serialize(HydraSrt.Api.CallerLabel.t()) :: map()
  def serialize(label) do
    %{
      id: label.id,
      address: label.address,
      label: label.label,
      note: label.note,
      inserted_at: label.inserted_at,
      updated_at: label.updated_at
    }
  end

  @spec data(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def data(conn, payload), do: json(conn, %{data: payload})
end

defmodule HydraSrtWeb.TokenController do
  use HydraSrtWeb, :controller

  alias HydraSrt.Db

  action_fallback HydraSrtWeb.FallbackController

  def index(conn, _params) do
    data(conn, Enum.map(Db.list_tokens(), &serialize_token/1))
  end

  def create(conn, %{"token" => token_params}) do
    with {:ok, token, raw_token} <- Db.create_token(token_params) do
      conn
      |> put_status(:created)
      |> data(serialize_token(token, raw_token: raw_token))
    end
  end

  def update(conn, %{"id" => id, "token" => token_params}) do
    with {:ok, token} <- Db.update_token(id, token_params) do
      data(conn, serialize_token(token))
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, _token} <- Db.delete_token(id) do
      send_resp(conn, :no_content, "")
    end
  end

  def data(conn, payload), do: json(conn, %{data: payload})

  def serialize_token(token, opts \\ []) do
    raw_token = Keyword.get(opts, :raw_token)

    base = %{
      id: token.id,
      name: token.name,
      inserted_at: token.inserted_at,
      updated_at: token.updated_at
    }

    if raw_token do
      Map.put(base, :token, raw_token)
    else
      base
    end
  end
end

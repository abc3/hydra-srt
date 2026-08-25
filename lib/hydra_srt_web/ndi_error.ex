defmodule HydraSrtWeb.NdiError do
  @moduledoc false

  @spec render(Plug.Conn.t(), pos_integer(), String.t(), String.t(), map()) :: Plug.Conn.t()
  def render(conn, status, code, message, errors \\ %{})
      when is_integer(status) and is_binary(code) and is_binary(message) and is_map(errors) do
    conn
    |> Plug.Conn.put_status(status)
    |> Phoenix.Controller.json(%{error: message, code: code, errors: errors})
  end
end

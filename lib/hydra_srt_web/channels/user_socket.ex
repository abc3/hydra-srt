defmodule HydraSrtWeb.UserSocket do
  use Phoenix.Socket

  channel "live:*", HydraSrtWeb.LiveChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Cachex.get(HydraSrt.Cache, "auth_session:#{token}") do
      {:ok, nil} ->
        :error

      {:ok, _value} ->
        {:ok, socket}

      _ ->
        :error
    end
  end

  @impl true
  def id(_socket), do: nil
end

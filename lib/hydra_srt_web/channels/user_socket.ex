defmodule HydraSrtWeb.UserSocket do
  use Phoenix.Socket

  channel "live:*", HydraSrtWeb.LiveChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    if HydraSrt.Auth.authenticate_session(token), do: {:ok, socket}, else: :error
  end

  @impl true
  def id(_socket), do: nil
end

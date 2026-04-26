defmodule HydraSrtWeb.UserSocket do
  use Phoenix.Socket

  channel "realtime", HydraSrtWeb.RealtimeChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) when is_binary(token) do
    if HydraSrt.Auth.authenticate_session(token) do
      {:ok, assign(socket, :authenticated, true)}
    else
      :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(_socket), do: nil
end

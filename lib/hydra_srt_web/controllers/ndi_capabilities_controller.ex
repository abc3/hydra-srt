defmodule HydraSrtWeb.NdiCapabilitiesController do
  @moduledoc """
  Serves the current NDI capability document.
  """

  use HydraSrtWeb, :controller

  alias HydraSrt.Ndi.Capabilities

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    json(conn, %{data: Capabilities.get()})
  end
end

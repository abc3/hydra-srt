defmodule HydraSrt.TestSupport.McpE2EClient.Impl do
  @moduledoc false

  use Hermes.Client,
    name: "HydraSRT MCP E2E",
    version: "1.0.0",
    protocol_version: "2025-03-26",
    capabilities: []
end

defmodule HydraSrt.TestSupport.McpE2EClient do
  @moduledoc false

  alias Hermes.Client.Base, as: ClientBase
  alias HydraSrt.TestSupport.E2EHelpers
  alias HydraSrt.TestSupport.McpE2EClient.Impl

  @accept "application/json, text/event-stream"

  @spec start_linked!(String.t(), keyword()) :: atom()
  def start_linked!(raw_token, opts \\ []) when is_binary(raw_token) do
    base_url = Keyword.get(opts, :base_url, E2EHelpers.base_url())
    name = Keyword.get(opts, :name, unique_name())

    {:ok, _supervisor} =
      Impl.start_link(
        client_name: name,
        client_info: %{"name" => "HydraSRT MCP E2E", "version" => "1.0.0"},
        capabilities: %{},
        protocol_version: "2025-03-26",
        transport:
          {:streamable_http,
           base_url: base_url,
           mcp_path: "/mcp",
           headers: %{"authorization" => "Bearer #{raw_token}"}}
      )

    wait_until_initialized!(name)
    name
  end

  @spec stop(atom()) :: :ok
  def stop(client) do
    _ = ClientBase.close(client)
    :ok
  end

  @spec call_tool(atom(), String.t(), map() | nil, keyword()) ::
          {:ok, Hermes.MCP.Response.t()} | {:error, term()}
  def call_tool(client, name, args \\ nil, opts \\ []),
    do: ClientBase.call_tool(client, name, args, opts)

  @spec list_tools(atom(), keyword()) :: {:ok, Hermes.MCP.Response.t()} | {:error, term()}
  def list_tools(client, opts \\ []), do: ClientBase.list_tools(client, opts)

  @spec ping(atom(), keyword()) :: :pong | {:error, term()}
  def ping(client, opts \\ []), do: ClientBase.ping(client, opts)

  @spec mcp_url(keyword()) :: String.t()
  def mcp_url(opts \\ []) do
    base_url = Keyword.get(opts, :base_url, E2EHelpers.base_url())
    base_url <> "/mcp"
  end

  @spec mcp_accept_header() :: String.t()
  def mcp_accept_header, do: @accept

  def unique_name do
    :"mcp_e2e_client_#{System.unique_integer([:positive])}"
  end

  def wait_until_initialized!(client, attempts \\ 50) do
    case ClientBase.ping(client, timeout: 5_000) do
      :pong ->
        client

      {:error, _reason} when attempts > 0 ->
        Process.sleep(100)
        wait_until_initialized!(client, attempts - 1)

      other ->
        raise "MCP E2E client failed to initialize: #{inspect(other)}"
    end
  end
end

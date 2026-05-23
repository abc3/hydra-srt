defmodule HydraSrt.TestSupport.McpE2EAssertions do
  @moduledoc false

  import ExUnit.Assertions

  alias Hermes.MCP.Response, as: McpResponse
  alias HydraSrt.TestSupport.E2EHelpers
  alias HydraSrt.TestSupport.McpE2EClient

  @spec assert_mcp_auth_rejected!(keyword()) :: :ok
  def assert_mcp_auth_rejected!(opts \\ []) do
    url = Keyword.get(opts, :url, McpE2EClient.mcp_url())
    headers = Keyword.get(opts, :headers, [])

    request_headers =
      [{"accept", McpE2EClient.mcp_accept_header()}, {"content-type", "application/json"}] ++
        headers

    {:ok, status, resp_headers, body} =
      E2EHelpers.http_raw(:post, url, request_headers, "{}")

    assert status == 401
    assert Jason.decode!(body)["error"]
    assert header_value(resp_headers, "www-authenticate") == "Bearer"
    :ok
  end

  @spec header_value([{term(), term()}], String.t()) :: String.t() | nil
  def header_value(headers, name) when is_binary(name) do
    Enum.find_value(headers, fn
      {key, value} when is_list(key) ->
        if String.downcase(to_string(key)) == String.downcase(name), do: to_string(value)

      {key, value} when is_atom(key) ->
        if Atom.to_string(key) == name, do: to_string(value)

      {key, value} when is_binary(key) ->
        if String.downcase(key) == String.downcase(name), do: to_string(value)

      _ ->
        nil
    end)
  end

  @spec assert_tool_success({:ok, McpResponse.t()} | {:error, term()}) :: map()
  def assert_tool_success(result) do
    assert {:ok, response} = result
    assert McpResponse.success?(response), "expected MCP tool success, got: #{inspect(response)}"

    structured = structured_content(response)
    assert is_map(structured), "expected structuredContent map, got: #{inspect(structured)}"
    refute Map.get(structured, "error"), "unexpected tool error: #{inspect(structured)}"
    assert Map.has_key?(structured, "data"), "expected data envelope in #{inspect(structured)}"
    assert {:ok, _} = Jason.encode(structured)
    structured
  end

  @spec assert_tool_responds({:ok, McpResponse.t()} | {:error, term()}) :: map()
  def assert_tool_responds(result) do
    assert {:ok, response} = result,
           "expected MCP protocol success, got: #{inspect(result)}"

    structured = structured_content(response)
    assert is_map(structured), "expected structuredContent map, got: #{inspect(structured)}"
    assert {:ok, _} = Jason.encode(structured)
    structured
  end

  @spec structured_content(McpResponse.t()) :: map() | nil
  def structured_content(%McpResponse{} = response) do
    response
    |> McpResponse.unwrap()
    |> Map.get("structuredContent")
  end
end

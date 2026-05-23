defmodule HydraSrt.E2E.Mcp.AuthTest do
  use HydraSrt.TestSupport.McpE2ECase

  @moduletag :skip_mcp_client
  @moduletag :skip_mcp_fixtures

  alias HydraSrt.Auth
  alias HydraSrt.Db
  alias HydraSrt.TestSupport.McpE2EAssertions, as: McpAssertions
  alias HydraSrt.TestSupport.McpE2EClient

  test "rejects requests without bearer token" do
    McpAssertions.assert_mcp_auth_rejected!()
  end

  test "rejects requests with invalid bearer token" do
    McpAssertions.assert_mcp_auth_rejected!(headers: [{"authorization", "Bearer invalid-token"}])
  end

  test "rejects login session token on mcp endpoint" do
    session_token = "test_session_#{System.unique_integer([:positive])}"
    {:ok, _session} = Auth.create_session(session_token, "user_session_data")

    McpAssertions.assert_mcp_auth_rejected!(
      headers: [{"authorization", "Bearer " <> session_token}]
    )
  end

  test "accepts valid bearer token and reaches MCP transport" do
    {:ok, _token, raw_token} =
      Db.create_token(%{"name" => "mcp-e2e-auth-#{System.unique_integer([:positive])}"})

    {:ok, status, _headers, body} =
      HydraSrt.TestSupport.E2EHelpers.http_raw(
        :post,
        McpE2EClient.mcp_url(),
        [
          {"authorization", "Bearer " <> raw_token},
          {"accept", McpE2EClient.mcp_accept_header()},
          {"content-type", "application/json"}
        ],
        "{}"
      )

    assert status == 400
    assert body =~ "jsonrpc"
    refute body =~ "Authorization header missing"
  end
end

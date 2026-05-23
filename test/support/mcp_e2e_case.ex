defmodule HydraSrt.TestSupport.McpE2ECase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false

      @moduletag :e2e_mcp

      alias HydraSrt.Db
      alias HydraSrt.TestSupport.E2EHelpers
      alias HydraSrt.TestSupport.McpE2EAssertions, as: McpAssertions
      alias HydraSrt.TestSupport.McpE2EClient
      alias HydraSrt.TestSupport.McpE2EFixtures, as: McpFixtures
    end
  end

  setup tags do
    if tags[:skip_mcp_client] do
      :ok
    else
      {:ok, _token, raw_token} =
        HydraSrt.Db.create_token(%{
          "name" =>
            "mcp-e2e-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
        })

      base_url = tags[:base_url] || HydraSrt.TestSupport.E2EHelpers.base_url()

      client =
        HydraSrt.TestSupport.McpE2EClient.start_linked!(raw_token, base_url: base_url)

      ctx =
        if tags[:skip_mcp_fixtures],
          do: nil,
          else: HydraSrt.TestSupport.McpE2EFixtures.seed_context!()

      on_exit(fn -> HydraSrt.TestSupport.McpE2EClient.stop(client) end)

      {:ok, client: client, ctx: ctx, raw_token: raw_token}
    end
  end
end

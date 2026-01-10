ExUnit.start()

# Repo is currently not started by the application supervisor; avoid hard-failing tests.
if Code.ensure_loaded?(HydraSrt.Repo) and function_exported?(HydraSrt.Repo, :__adapter__, 0) do
  case Process.whereis(HydraSrt.Repo) do
    pid when is_pid(pid) -> Ecto.Adapters.SQL.Sandbox.mode(HydraSrt.Repo, :manual)
    _ -> :ok
  end
end

if System.get_env("E2E") == "true" do
  # E2E suite needs the real HTTP server + API auth
  HydraSrt.TestSupport.E2EHelpers.ensure_e2e_prereqs!()
end

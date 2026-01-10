ExUnit.start()

# Unless explicitly running E2E, exclude E2E-tagged tests from the unit suite.
if System.get_env("E2E") != "true" do
  ExUnit.configure(exclude: [e2e: true])
end

if System.get_env("E2E") == "true" do
  HydraSrt.TestSupport.E2EHelpers.ensure_endpoint_server_started!()
end

# Repo is currently not started by the application supervisor; avoid hard-failing tests.
if Code.ensure_loaded?(HydraSrt.Repo) and function_exported?(HydraSrt.Repo, :__adapter__, 0) do
  case Process.whereis(HydraSrt.Repo) do
    pid when is_pid(pid) ->
      Ecto.Adapters.SQL.Sandbox.mode(HydraSrt.Repo, :manual)

    _ ->
      :ok
  end
end

IO.puts("DEBUG: Checking Khepri...")

case Process.whereis(:khepri) do
  pid when is_pid(pid) -> IO.puts("DEBUG: Khepri is running at #{inspect(pid)}")
  nil -> IO.puts("DEBUG: Khepri is NOT running!")
end

if System.get_env("E2E") == "true" do
  # E2E suite needs the real HTTP server + API auth
  HydraSrt.TestSupport.E2EHelpers.ensure_e2e_prereqs!()

  if not HydraSrt.TestSupport.E2EHelpers.ffmpeg_supports_srt_encryption?() do
    IO.puts(
      "WARN: ffmpeg SRT encryption (passphrase/pbkeylen) not supported; excluding :encrypted E2E tests"
    )

    ExUnit.configure(exclude: [:encrypted])
  end

  ExUnit.after_suite(fn _ -> HydraSrt.TestSupport.E2EHelpers.kill_all_pipelines!() end)
end

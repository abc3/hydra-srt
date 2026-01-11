ExUnit.start()

# Opt-in helpers for debugging hangs:
# - TRACE=true       -> prints every test name as it runs
# - SLOWEST=true     -> prints slowest tests at end (ExUnit 1.13+)
# - TEST_TIMEOUT=ms  -> per-test timeout override
if System.get_env("TRACE") == "true" do
  ExUnit.configure(trace: true)
end

if System.get_env("SLOWEST") == "true" do
  ExUnit.configure(slowest: 10)
end

case System.get_env("TEST_TIMEOUT") do
  nil ->
    :ok

  timeout_ms_str ->
    case Integer.parse(timeout_ms_str) do
      {timeout_ms, _} when timeout_ms > 0 -> ExUnit.configure(timeout: timeout_ms)
      _ -> :ok
    end
end

# Unless explicitly running E2E, exclude E2E-tagged tests from the unit suite.
if System.get_env("E2E") != "true" do
  ExUnit.configure(exclude: [e2e: true])
end

if System.get_env("E2E") != "true" do
  # Unit tests use SQL Sandbox.
  if Code.ensure_loaded?(HydraSrt.Repo) and function_exported?(HydraSrt.Repo, :__adapter__, 0) do
    case Process.whereis(HydraSrt.Repo) do
      pid when is_pid(pid) ->
        Ecto.Adapters.SQL.Sandbox.mode(HydraSrt.Repo, :manual)

      _ ->
        :ok
    end
  end
end

if System.get_env("E2E") == "true" do
  # E2E suite needs the real HTTP server + API auth
  HydraSrt.TestSupport.E2EHelpers.ensure_e2e_prereqs!()
  HydraSrt.TestSupport.E2EHelpers.ensure_endpoint_server_started!()

  if not HydraSrt.TestSupport.E2EHelpers.ffmpeg_supports_srt_encryption?() do
    IO.puts(
      "WARN: ffmpeg SRT encryption (passphrase/pbkeylen) not supported; excluding :encrypted E2E tests"
    )

    ExUnit.configure(exclude: [:encrypted])
  end

  ExUnit.after_suite(fn _ -> HydraSrt.TestSupport.E2EHelpers.kill_all_pipelines!() end)
end

ExUnit.start()

test_args = System.argv()

e2e_mode_enabled? =
  System.get_env("E2E") == "true" or
    Enum.chunk_every(test_args, 2, 1, :discard)
    |> Enum.any?(fn
      ["--only", tag] -> String.starts_with?(tag, "e2e")
      ["--include", tag] -> String.starts_with?(tag, "e2e")
      _ -> false
    end)

# Opt-in helpers for debugging hangs:
# - TRACE=true       -> prints every test name as it runs
# - SLOWEST=true     -> prints slowest tests at end (ExUnit 1.13+)
# - TEST_TIMEOUT=ms  -> per-test timeout override
# - E2E_DEBUG_LOGS=true -> prints full stdout/stderr from external E2E helper processes
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

[
  "test/native_e2e/support/process_registry.ex",
  "test/native_e2e/support/udp_listener.ex",
  "test/native_e2e/support/native_helpers.ex",
  "test/native_e2e/support/rs_native_harness.ex"
]
|> Enum.each(&Code.require_file/1)

excludes = []

excludes =
  if not e2e_mode_enabled? do
    [e2e: true] ++ excludes
  else
    excludes
  end

excludes =
  if System.get_env("NATIVE_E2E") != "true" do
    [native_e2e: true] ++ excludes
  else
    excludes
  end

if excludes != [] do
  ExUnit.configure(exclude: excludes)
end

if not e2e_mode_enabled? do
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

if e2e_mode_enabled? do
  # One shared HTTP endpoint + one SQLite file: parallel ExUnit cases contend on DB
  # locks and route lifecycle, causing flaky "database is locked" / pipeline timeouts.
  ExUnit.configure(max_cases: 1)

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

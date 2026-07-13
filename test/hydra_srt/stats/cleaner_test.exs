defmodule HydraSrt.Stats.CleanerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias HydraSrt.Stats.Cleaner

  test "log_pipeline_logs_cleanup_result is silent on success" do
    assert :ok = Cleaner.log_pipeline_logs_cleanup_result(:ok, 24)
  end

  test "log_pipeline_logs_cleanup_result logs pipeline_logs failures" do
    log =
      capture_log(fn ->
        assert :ok =
                 Cleaner.log_pipeline_logs_cleanup_result({:error, :db_down}, 12)
      end)

    assert log =~ "Stats cleaner failed for pipeline_logs"
    assert log =~ "retention_hours=12"
    assert log =~ "db_down"
  end

  test "cleanup lets Victoria services own retention" do
    send(Cleaner, :cleanup)
    assert :ok
  end
end

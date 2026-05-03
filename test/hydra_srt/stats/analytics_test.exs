defmodule HydraSrt.Stats.AnalyticsTest do
  use ExUnit.Case, async: true

  alias HydraSrt.Stats.Analytics

  test "build_query_params resolves known window" do
    assert {:ok, params} = Analytics.build_query_params(%{"window" => "last_hour"})
    assert params.window == "last_hour"
    assert params.bucket_ms == 10_000
    assert DateTime.compare(params.from, params.to) == :lt
  end

  test "source_timeline_from_switches builds contiguous segments" do
    query = %{to: ~U[2026-05-01 12:30:00Z]}

    switches = [
      %{"ts" => ~U[2026-05-01 12:00:00Z], "to_source_id" => "s1"},
      %{"ts" => ~U[2026-05-01 12:05:00Z], "to_source_id" => "s2"},
      %{"ts" => ~U[2026-05-01 12:10:00Z], "to_source_id" => "s2"},
      %{"ts" => ~U[2026-05-01 12:20:00Z], "to_source_id" => "s3"}
    ]

    assert [
             %{
               "from" => "2026-05-01T12:00:00Z",
               "to" => "2026-05-01T12:05:00Z",
               "source_id" => "s1"
             },
             %{
               "from" => "2026-05-01T12:05:00Z",
               "to" => "2026-05-01T12:20:00Z",
               "source_id" => "s2"
             },
             %{
               "from" => "2026-05-01T12:20:00Z",
               "to" => "2026-05-01T12:30:00Z",
               "source_id" => "s3"
             }
           ] = Analytics.source_timeline_from_switches(switches, query)
  end
end

defmodule HydraSrt.Mcp.HelpersTest do
  use ExUnit.Case, async: true

  alias HydraSrt.Mcp.Helpers

  test "ok wraps payload in data envelope" do
    response = Helpers.ok(%{"id" => "route-1"})

    assert response.structured_content == %{"data" => %{"id" => "route-1"}}
    assert response.isError == false
  end

  test "error_response sets isError and error payload" do
    response = Helpers.error_response("Not found")

    assert response.isError == true
    assert response.structured_content == %{"error" => "Not found"}
  end

  test "unknown_tool returns structured unknown-tool error" do
    response = Helpers.unknown_tool("missing_tool")

    assert response.isError == true
    assert response.structured_content == %{"error" => "Unknown tool: missing_tool"}
  end

  test "from_result maps not_found" do
    response = Helpers.from_result({:error, :not_found})

    assert response.isError == true
    assert response.structured_content["error"] == "Not found"
  end

  test "ok serializes DateTime values to ISO8601 strings" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    response = Helpers.ok(%{"ts" => now})

    assert response.structured_content == %{"data" => %{"ts" => DateTime.to_iso8601(now)}}
    assert {:ok, _} = Jason.encode(response.structured_content)
  end

  test "ok serializes NaiveDateTime values to ISO8601 strings" do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    response = Helpers.ok(%{"ts" => now})

    assert response.structured_content == %{"data" => %{"ts" => NaiveDateTime.to_iso8601(now)}}
    assert {:ok, _} = Jason.encode(response.structured_content)
  end

  test "map_with_error passes through tool validation errors" do
    validation_error = Helpers.error_response("Missing required 'route_id' parameter")

    assert Helpers.map_with_error({:error, validation_error}, fn _ ->
             Helpers.error_response("should not run")
           end) == {:ok, validation_error}
  end
end

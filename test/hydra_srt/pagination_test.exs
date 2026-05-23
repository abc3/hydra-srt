defmodule HydraSrt.PaginationTest do
  use ExUnit.Case, async: true

  alias HydraSrt.Pagination

  test "parse_page and parse_limit use defaults for invalid values" do
    assert Pagination.parse_page(%{}) == 1
    assert Pagination.parse_limit(%{}) == 50
    assert Pagination.parse_page(%{"page" => "0"}) == 1
    assert Pagination.parse_limit(%{"limit" => "-1"}) == 50
  end

  test "parse_sort_by accepts allowed values only" do
    assert Pagination.parse_sort_by(%{"sort_by" => "updated_at"}) == "updated_at"
    assert Pagination.parse_sort_by(%{"sort_by" => "invalid"}) == "created_at"
  end
end

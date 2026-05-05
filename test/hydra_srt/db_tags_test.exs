defmodule HydraSrt.DbTagsTest do
  use HydraSrt.DataCase

  alias HydraSrt.Db

  import HydraSrt.DbFixtures

  test "list_all_tags/0 returns empty list when no tags exist" do
    assert Db.list_all_tags() == []
  end

  test "list_all_tags/0 returns all tag names" do
    route_fixture(%{"tags" => ["sport", "news"]})
    route_fixture(%{"tags" => ["news", "live"]})

    assert Enum.sort(Db.list_all_tags()) == ["live", "news", "sport"]
  end

  test "create_route/1 persists tags via route_tags join" do
    {:ok, route} = Db.create_route(%{"name" => "tagged route", "tags" => ["sport", "live"]})

    assert Enum.sort(route["tags"]) == ["live", "sport"]
  end

  test "update_route/2 replaces tags" do
    {:ok, route} = Db.create_route(%{"name" => "my route", "tags" => ["sport"]})

    {:ok, updated} = Db.update_route(route["id"], %{"tags" => ["news", "live"]})

    assert Enum.sort(updated["tags"]) == ["live", "news"]
  end

  test "update_route/2 without tags key leaves tags unchanged" do
    {:ok, route} = Db.create_route(%{"name" => "my route", "tags" => ["sport"]})

    {:ok, updated} = Db.update_route(route["id"], %{"name" => "renamed"})

    assert updated["tags"] == ["sport"]
  end

  test "update_route/2 supports atom tags key" do
    {:ok, route} = Db.create_route(%{"name" => "my route", "tags" => ["sport"]})

    {:ok, updated} = Db.update_route(route["id"], %{tags: ["news"]})

    assert updated["tags"] == ["news"]
  end

  test "route tags default to empty list" do
    route = route_fixture()

    assert route["tags"] == []
  end

  test "upsert_tags_by_name/1 reuses existing tags" do
    Db.upsert_tags_by_name(["sport"])
    Db.upsert_tags_by_name(["sport"])

    assert Db.list_all_tags() == ["sport"]
  end
end

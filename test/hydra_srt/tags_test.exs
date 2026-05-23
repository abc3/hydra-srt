defmodule HydraSrt.TagsTest do
  use HydraSrt.DataCase, async: false

  alias HydraSrt.Tags

  test "list returns serialized tags with timestamps" do
    assert {:ok, tag} = Tags.create(%{"name" => "shared-tag"})

    listed = Enum.find(Tags.list(), &(&1[:id] == tag[:id]))
    assert listed[:name] == "shared-tag"
    assert listed[:inserted_at] == tag[:inserted_at]
  end

  test "delete returns tag record" do
    assert {:ok, tag} = Tags.create(%{"name" => "delete-me"})
    assert {:ok, deleted} = Tags.delete(tag[:id])
    assert deleted[:id] == tag[:id]
  end
end

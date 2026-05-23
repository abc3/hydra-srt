defmodule HydraSrt.DbTokensTest do
  use HydraSrt.DataCase

  alias HydraSrt.Auth
  alias HydraSrt.Db

  test "list_tokens/0 returns empty list when no tokens exist" do
    assert Db.list_tokens() == []
  end

  test "create_token/1 generates token and stores hashed value" do
    assert {:ok, token, raw_token} = Db.create_token(%{"name" => "cursor"})
    assert token.name == "cursor"
    assert is_binary(raw_token)
    assert token.hash == Auth.hash_token(raw_token)
    assert Db.authenticate_mcp_token(raw_token)
  end

  test "update_token/2 updates name only" do
    {:ok, token, raw_token} = Db.create_token(%{"name" => "old name"})

    assert {:ok, updated} = Db.update_token(token.id, %{"name" => "new name"})
    assert updated.name == "new name"
    assert updated.hash == token.hash
    assert Db.authenticate_mcp_token(raw_token)
  end

  test "delete_token/1 removes token" do
    {:ok, token, raw_token} = Db.create_token(%{"name" => "temporary"})

    assert {:ok, _} = Db.delete_token(token.id)
    assert Db.list_tokens() == []
    refute Db.authenticate_mcp_token(raw_token)
  end

  test "authenticate_mcp_token/1 returns false for unknown token" do
    refute Db.authenticate_mcp_token("unknown-token")
  end

  test "create_token/1 rejects duplicate names" do
    assert {:ok, _, _} = Db.create_token(%{"name" => "cursor"})
    assert {:error, %Ecto.Changeset{}} = Db.create_token(%{"name" => "cursor"})
  end

  test "create_token/1 rejects blank name" do
    assert {:error, %Ecto.Changeset{}} = Db.create_token(%{"name" => "   "})
  end
end

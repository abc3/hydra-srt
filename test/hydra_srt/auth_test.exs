defmodule HydraSrt.AuthTest do
  use HydraSrt.DataCase

  alias HydraSrt.Auth
  alias HydraSrt.AuthSession
  alias HydraSrt.Repo

  defp hashed_token(token) do
    HydraSrt.Auth.hash_token(token)
  end

  test "creates session in sqlite and cache" do
    token = "token-#{System.unique_integer([:positive])}"
    token_hash = hashed_token(token)

    assert {:ok, session} = Auth.create_session(token, "admin")
    assert session.token == token_hash

    assert %AuthSession{token: ^token_hash, user: "admin"} = Repo.get(AuthSession, token_hash)
    assert {:ok, "admin"} = Cachex.get(HydraSrt.Cache, "auth_session:#{token_hash}")
  end

  test "restores cache from sqlite when cache entry is missing" do
    token = "token-#{System.unique_integer([:positive])}"
    token_hash = hashed_token(token)
    assert {:ok, _session} = Auth.create_session(token, "admin")

    assert {:ok, true} = Cachex.del(HydraSrt.Cache, "auth_session:#{token_hash}")
    assert {:ok, nil} = Cachex.get(HydraSrt.Cache, "auth_session:#{token_hash}")

    assert Auth.authenticate_session(token)
    assert {:ok, "admin"} = Cachex.get(HydraSrt.Cache, "auth_session:#{token_hash}")
  end

  test "caches invalid tokens to avoid repeated db lookups" do
    token = "missing-token-#{System.unique_integer([:positive])}"
    token_hash = hashed_token(token)

    refute Auth.authenticate_session(token)
    assert {:ok, :not_found} = Cachex.get(HydraSrt.Cache, "auth_session:#{token_hash}")
  end

  test "expired sessions are rejected and removed from sqlite" do
    token = "expired-token-#{System.unique_integer([:positive])}"
    token_hash = hashed_token(token)

    assert {:ok, _session} =
             %AuthSession{}
             |> AuthSession.changeset(%{
               token: token_hash,
               user: "admin",
               expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
             })
             |> Repo.insert()

    refute Auth.authenticate_session(token)
    assert Repo.get(AuthSession, token_hash) == nil
  end
end

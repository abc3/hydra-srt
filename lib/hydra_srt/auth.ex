defmodule HydraSrt.Auth do
  @moduledoc false
  import Ecto.Query, warn: false

  alias HydraSrt.AuthSession
  alias HydraSrt.Repo

  @session_ttl_seconds 14 * 24 * 60 * 60
  @negative_cache_ttl_ms :timer.minutes(5)
  @not_found :not_found

  @spec session_ttl_seconds() :: pos_integer()
  def session_ttl_seconds, do: @session_ttl_seconds

  @spec create_session(binary(), binary()) :: {:ok, AuthSession.t()} | {:error, term()}
  def create_session(token, user) when is_binary(token) and is_binary(user) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, @session_ttl_seconds, :second)
    hashed_token = hash_token(token)

    %AuthSession{}
    |> AuthSession.changeset(%{token: hashed_token, user: user, expires_at: expires_at})
    |> Repo.insert(
      on_conflict: [set: [user: user, expires_at: expires_at, updated_at: now]],
      conflict_target: [:token]
    )
    |> case do
      {:ok, session} ->
        cache_session(hashed_token, user, expires_at, now)
        {:ok, session}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec authenticate_session(binary()) :: boolean()
  def authenticate_session(token) when is_binary(token) do
    now = DateTime.utc_now()
    hashed_token = hash_token(token)

    case Cachex.get(HydraSrt.Cache, cache_key(hashed_token)) do
      {:ok, @not_found} ->
        false

      {:ok, nil} ->
        authenticate_session_from_db(token, hashed_token, now)

      {:ok, _user} ->
        true

      {:error, _reason} ->
        authenticate_session_from_db(token, hashed_token, now)
    end
  end

  @spec valid_session?(binary()) :: boolean()
  def valid_session?(token) when is_binary(token) do
    authenticate_session(token)
  end

  @spec startup_cleanup() :: :ok
  def startup_cleanup do
    delete_expired_sessions()
  end

  @spec delete_expired_sessions() :: :ok
  def delete_expired_sessions do
    now = DateTime.utc_now()

    from(s in AuthSession, where: s.expires_at <= ^now)
    |> Repo.delete_all()

    :ok
  end

  def delete_session(token) when is_binary(token) do
    hashed_token = hash_token(token)

    delete_session_by_hash(hashed_token)
  end

  @spec hash_token(binary()) :: binary()
  def hash_token(token) when is_binary(token) do
    :crypto.hash(:sha256, token)
    |> Base.encode16(case: :lower)
  end

  defp delete_session_by_hash(hashed_token) do
    Cachex.del(HydraSrt.Cache, cache_key(hashed_token))
    Repo.delete_all(from(s in AuthSession, where: s.token == ^hashed_token))
    :ok
  end

  defp authenticate_session_from_db(_token, hashed_token, now) do
    case Repo.get(AuthSession, hashed_token) do
      %AuthSession{} = session ->
        if DateTime.compare(session.expires_at, now) == :gt do
          cache_session(hashed_token, session.user, session.expires_at, now)
          true
        else
          delete_session_by_hash(hashed_token)
          false
        end

      nil ->
        cache_negative_result(hashed_token)
        false
    end
  end

  defp cache_session(hashed_token, user, expires_at, now) do
    ttl =
      expires_at
      |> DateTime.diff(now, :millisecond)
      |> max(1)

    Cachex.put(HydraSrt.Cache, cache_key(hashed_token), user, ttl: ttl)
  end

  defp cache_negative_result(hashed_token) do
    Cachex.put(HydraSrt.Cache, cache_key(hashed_token), @not_found, ttl: @negative_cache_ttl_ms)
  end

  defp cache_key(hashed_token), do: "auth_session:#{hashed_token}"
end

defmodule HydraSrt.AuthSession do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  # The `token` column stores a SHA-256 hash of the bearer token, not the raw token itself.
  @primary_key {:token, :string, autogenerate: false}
  schema "auth_sessions" do
    field :user, :string
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:token, :user, :expires_at])
    |> validate_required([:token, :user, :expires_at])
  end
end

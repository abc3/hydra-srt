defmodule HydraSrt.Api.Token do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tokens" do
    field :name, :string
    field :hash, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(token, attrs) do
    token
    |> cast(attrs, [:name, :hash])
    |> validate_required([:name, :hash])
    |> unique_constraint(:name)
    |> unique_constraint(:hash)
  end
end

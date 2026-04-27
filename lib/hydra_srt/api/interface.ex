defmodule HydraSrt.Api.Interface do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "interfaces" do
    field :name, :string
    field :ip, :string
    field :sys_name, :string
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(interface, attrs) do
    interface
    |> cast(attrs, [:name, :sys_name, :ip, :enabled])
    |> validate_required([:sys_name, :ip, :enabled])
    |> unique_constraint(:sys_name)
  end
end

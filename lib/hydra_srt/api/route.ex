defmodule HydraSrt.Api.Route do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "routes" do
    field :alias, :string
    field :enabled, :boolean, default: false
    field :name, :string
    field :status, :string
    field :started_at, :utc_datetime
    field :source, :map
    field :destinations, :map
    field :stopped_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(route, attrs) do
    route
    |> cast(attrs, [
      :enabled,
      :name,
      :alias,
      :status,
      :source,
      :destinations,
      :started_at,
      :stopped_at
    ])
    |> validate_required([:enabled, :name, :alias, :status, :started_at, :stopped_at])
  end
end

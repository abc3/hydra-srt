defmodule HydraSrt.Api.Destination do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "destinations" do
    # NOTE: This schema was originally used as a lightweight validator for the Khepri-backed API.
    field :enabled, :boolean, default: true
    field :name, :string
    field :status, :string
    field :schema, :string
    field :schema_options, :map
    field :node, :string

    field :alias, :string
    field :started_at, :utc_datetime
    field :stopped_at, :utc_datetime
    field :lock_version, :integer, default: 1

    field :route_id, :binary_id
    belongs_to :route, HydraSrt.Api.Route, define_field: false, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(destination, attrs) do
    destination
    |> cast(attrs, [
      :route_id,
      :enabled,
      :name,
      :alias,
      :status,
      :schema,
      :schema_options,
      :node,
      :started_at,
      :stopped_at
    ])
    |> validate_required([:route_id, :schema, :schema_options])
    |> optimistic_lock(:lock_version)
  end
end

defmodule HydraSrt.Api.Destination do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "destinations" do
    # NOTE: This schema is used as a lightweight validator for the Khepri-backed API.
    # Destinations are posted as:
    #   %{name?, enabled?, schema, schema_options, node?, ...}
    field :enabled, :boolean, default: true
    field :name, :string
    field :status, :string
    field :schema, :string
    field :schema_options, :map
    field :node, :string

    field :alias, :string
    field :started_at, :utc_datetime
    field :stopped_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(destination, attrs) do
    destination
    |> cast(attrs, [
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
    |> validate_required([:schema, :schema_options])
  end
end

defmodule HydraSrt.Api.Source do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "sources" do
    field :position, :integer, default: 0
    field :enabled, :boolean, default: true
    field :name, :string
    field :schema, :string
    field :schema_options, :map, default: %{}
    field :status, :string
    field :last_probe_at, :utc_datetime_usec
    field :last_failure_at, :utc_datetime_usec
    field :route_id, :binary_id

    belongs_to :route, HydraSrt.Api.Route, define_field: false, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(source, attrs) do
    source
    |> cast(attrs, [
      :route_id,
      :position,
      :enabled,
      :name,
      :schema,
      :schema_options,
      :status,
      :last_probe_at,
      :last_failure_at
    ])
    |> validate_required([:route_id, :position, :schema])
    |> validate_inclusion(:schema, ["SRT", "UDP"])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint([:route_id, :position])
  end
end

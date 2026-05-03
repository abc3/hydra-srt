defmodule HydraSrt.Api.Endpoint do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  @source_type "source"
  @destination_type "destination"
  @source_unique_constraint :endpoints_route_id_position_type_index

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "endpoints" do
    field :type, :string
    field :position, :integer, default: 0
    field :enabled, :boolean, default: false
    field :name, :string
    field :alias, :string
    field :status, :string
    field :schema, :string
    field :schema_options, :map, default: %{}
    field :node, :string
    field :started_at, :utc_datetime
    field :stopped_at, :utc_datetime
    field :lock_version, :integer, default: 1
    field :last_probe_at, :utc_datetime_usec
    field :last_failure_at, :utc_datetime_usec
    field :route_id, :binary_id

    belongs_to :route, HydraSrt.Api.Route, define_field: false, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  def source_type, do: @source_type
  def destination_type, do: @destination_type

  def source_scope(query \\ __MODULE__) do
    from(e in query, where: e.type == ^@source_type)
  end

  def destination_scope(query \\ __MODULE__) do
    from(e in query, where: e.type == ^@destination_type)
  end

  def source_changeset(endpoint, attrs) do
    endpoint
    |> cast_common(attrs)
    |> put_change(:type, @source_type)
    |> put_default_enabled(true)
    |> validate_required([:route_id, :position, :schema, :type])
    |> validate_inclusion(:schema, ["SRT", "UDP"])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint([:route_id, :position, :type], name: @source_unique_constraint)
    |> optimistic_lock(:lock_version)
  end

  def destination_changeset(endpoint, attrs) do
    endpoint
    |> cast_common(attrs)
    |> put_change(:type, @destination_type)
    |> put_default_enabled(false)
    |> validate_required([:route_id, :schema, :schema_options, :type])
    |> unique_constraint([:route_id, :position, :type], name: @source_unique_constraint)
    |> optimistic_lock(:lock_version)
  end

  defp cast_common(endpoint, attrs) do
    cast(endpoint, attrs, [
      :route_id,
      :position,
      :enabled,
      :name,
      :alias,
      :status,
      :schema,
      :schema_options,
      :node,
      :started_at,
      :stopped_at,
      :last_probe_at,
      :last_failure_at
    ])
  end

  defp put_default_enabled(changeset, default) do
    case fetch_field(changeset, :enabled) do
      {_, nil} -> put_change(changeset, :enabled, default)
      _ -> changeset
    end
  end
end

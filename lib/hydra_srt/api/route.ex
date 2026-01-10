defmodule HydraSrt.Api.Route do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "routes" do
    # NOTE: This schema is used as a lightweight validator for the Khepri-backed API.
    # The admin UI + E2E suite post payloads shaped like:
    #   %{name, enabled, exportStats, schema, schema_options, node, gstDebug, ...}
    # (not the scaffolded alias/started_at/stopped_at fields).
    field :enabled, :boolean, default: true
    field :name, :string
    field :status, :string
    field :exportStats, :boolean, default: false
    field :schema, :string
    field :schema_options, :map
    field :node, :string
    field :gstDebug, :string

    field :alias, :string
    field :source, :map
    field :destinations, {:array, :map}
    field :started_at, :utc_datetime
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
      :exportStats,
      :schema,
      :schema_options,
      :node,
      :gstDebug,
      :source,
      :destinations,
      :started_at,
      :stopped_at
    ])
    # For now, require only minimal fields to not break existing logic too hard,
    # or align with what's actually mandatory. The previous code required:
    |> validate_required([:name])
  end
end

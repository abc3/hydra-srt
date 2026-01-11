defmodule HydraSrt.Api.Route do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "routes" do
    # NOTE: This schema was originally used as a lightweight validator for the Khepri-backed API.
    # We keep compatibility with the admin UI payload keys (camelCase) at the changeset layer.
    field :enabled, :boolean, default: true
    field :name, :string
    field :status, :string
    field :export_stats, :boolean, default: false
    field :schema, :string
    field :schema_options, :map
    field :node, :string
    field :gst_debug, :string

    field :alias, :string
    field :source, :map
    field :destinations_legacy, :map, source: :destinations
    field :started_at, :utc_datetime
    field :stopped_at, :utc_datetime
    field :lock_version, :integer, default: 1

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(route, attrs) do
    attrs = normalize_attrs(attrs)

    route
    |> cast(attrs, [
      :enabled,
      :name,
      :alias,
      :status,
      :export_stats,
      :schema,
      :schema_options,
      :node,
      :gst_debug,
      :source,
      :started_at,
      :stopped_at
    ])
    # For now, require only minimal fields to not break existing logic too hard,
    # or align with what's actually mandatory. The previous code required:
    |> validate_required([:name])
    |> optimistic_lock(:lock_version)
  end

  @doc false
  def normalize_attrs(attrs) when is_map(attrs) do
    atom_keys? = Enum.any?(Map.keys(attrs), &is_atom/1)

    export_stats_key = if atom_keys?, do: :export_stats, else: "export_stats"
    gst_debug_key = if atom_keys?, do: :gst_debug, else: "gst_debug"

    attrs
    |> normalize_key("exportStats", export_stats_key)
    |> normalize_key(:exportStats, export_stats_key)
    |> normalize_key("gstDebug", gst_debug_key)
    |> normalize_key(:gstDebug, gst_debug_key)
  end

  @doc false
  def normalize_attrs(attrs), do: attrs

  @doc false
  def normalize_key(attrs, from_key, to_key) when is_map(attrs) do
    case Map.fetch(attrs, from_key) do
      {:ok, value} -> Map.put_new(attrs, to_key, value)
      :error -> attrs
    end
  end
end

defmodule HydraSrt.Api.Route do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "routes" do
    # We keep compatibility with the admin UI payload keys (camelCase) at the changeset layer.
    field :enabled, :boolean, default: false
    field :name, :string
    field :status, :string
    field :schema_status, :string
    field :schema, :string
    field :schema_options, :map
    field :node, :string
    field :gst_debug, :string

    field :alias, :string
    field :source, :map
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
      :schema_status,
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
    gst_debug_key =
      if Enum.any?(Map.keys(attrs), &is_atom/1), do: :gst_debug, else: "gst_debug"

    attrs
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

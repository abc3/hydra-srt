defmodule HydraSrt.Api.Route do
  use Ecto.Schema
  import Ecto.Changeset
  alias HydraSrt.Api.Endpoint

  @source_type Endpoint.source_type()
  @destination_type Endpoint.destination_type()

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "routes" do
    # We keep compatibility with the admin UI payload keys (camelCase) at the changeset layer.
    field :enabled, :boolean, default: false
    field :name, :string
    field :status, :string
    field :schema_status, :string
    field :node, :string
    field :gst_debug, :string, default: "2"
    field :backup_mode, :string, default: "passive"
    field :backup_switch_after_ms, :integer, default: 3000
    field :backup_cooldown_ms, :integer, default: 10000
    field :backup_primary_stable_ms, :integer, default: 15000
    field :backup_probe_interval_ms, :integer, default: 5000
    field :last_switch_reason, :string
    field :last_switch_at, :utc_datetime_usec

    field :alias, :string
    field :source, :map
    field :started_at, :utc_datetime
    field :stopped_at, :utc_datetime
    field :lock_version, :integer, default: 1

    belongs_to :active_source, HydraSrt.Api.Endpoint, type: :binary_id

    many_to_many :tags, HydraSrt.Api.Tag, join_through: "route_tags", on_replace: :delete

    has_many :sources, HydraSrt.Api.Endpoint,
      where: [type: @source_type],
      preload_order: [asc: :position]

    has_many :destinations, HydraSrt.Api.Endpoint,
      where: [type: @destination_type],
      preload_order: [desc: :inserted_at]

    timestamps(type: :utc_datetime_usec)
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
      :node,
      :gst_debug,
      :backup_mode,
      :backup_switch_after_ms,
      :backup_cooldown_ms,
      :backup_primary_stable_ms,
      :backup_probe_interval_ms,
      :active_source_id,
      :last_switch_reason,
      :last_switch_at,
      :source,
      :started_at,
      :stopped_at
    ])
    # For now, require only minimal fields to not break existing logic too hard,
    # or align with what's actually mandatory. The previous code required:
    |> validate_required([:name])
    |> validate_backup_fields()
    |> optimistic_lock(:lock_version)
  end

  @doc false
  def normalize_attrs(attrs) when is_map(attrs) do
    is_atom_map = Enum.any?(Map.keys(attrs), &is_atom/1)
    gst_debug_key = if is_atom_map, do: :gst_debug, else: "gst_debug"
    tags_key = if is_atom_map, do: :tags, else: "tags"

    attrs
    |> normalize_key("gstDebug", gst_debug_key)
    |> normalize_key(:gstDebug, gst_debug_key)
    |> normalize_key("tags", tags_key)
    |> normalize_key(:tags, tags_key)
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

  defp validate_backup_fields(changeset) do
    mode = get_field(changeset, :backup_mode) || "passive"
    allowed_modes = ["active", "passive", "disabled"]

    changeset =
      if mode in allowed_modes do
        changeset
      else
        add_error(changeset, :backup_mode, "must be active, passive or disabled")
      end

    numeric_fields = [
      :backup_switch_after_ms,
      :backup_cooldown_ms,
      :backup_primary_stable_ms,
      :backup_probe_interval_ms
    ]

    Enum.reduce(numeric_fields, changeset, fn field, acc ->
      case get_field(acc, field) do
        nil ->
          acc

        value when is_integer(value) and value >= 0 ->
          acc

        _ ->
          add_error(acc, field, "must be a non-negative integer")
      end
    end)
  end
end

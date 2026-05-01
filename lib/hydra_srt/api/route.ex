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
    field :node, :string
    field :gst_debug, :string
    field :backup_config, :map, default: %{}
    field :last_switch_reason, :string
    field :last_switch_at, :utc_datetime_usec

    field :alias, :string
    field :source, :map
    field :started_at, :utc_datetime
    field :stopped_at, :utc_datetime
    field :lock_version, :integer, default: 1

    belongs_to :active_source, HydraSrt.Api.Source, type: :binary_id
    has_many :sources, HydraSrt.Api.Source, preload_order: [asc: :position]

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
      :backup_config,
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
    |> validate_backup_config()
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

  defp validate_backup_config(changeset) do
    backup_config = get_field(changeset, :backup_config) || %{}
    mode = Map.get(backup_config, "mode", "passive")

    allowed_modes = ["active", "passive", "disabled"]

    changeset =
      if mode in allowed_modes do
        changeset
      else
        add_error(changeset, :backup_config, "mode must be active, passive or disabled")
      end

    numeric_keys = ["switch_after_ms", "cooldown_ms", "primary_stable_ms", "probe_interval_ms"]

    Enum.reduce(numeric_keys, changeset, fn key, acc ->
      case Map.get(backup_config, key) do
        nil ->
          acc

        value when is_integer(value) and value >= 0 ->
          acc

        _ ->
          add_error(acc, :backup_config, "#{key} must be a non-negative integer")
      end
    end)
  end
end

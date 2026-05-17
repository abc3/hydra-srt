defmodule HydraSrt.Api.Notification do
  use Ecto.Schema
  import Ecto.Changeset

  @telegram_type "telegram"
  @allowed_types [@telegram_type]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "notifications" do
    field :type, :string
    field :enabled, :boolean, default: false
    field :config, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def telegram_type, do: @telegram_type

  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [:type, :enabled, :config])
    |> validate_required([:type, :enabled, :config])
    |> validate_inclusion(:type, @allowed_types)
    |> validate_telegram_config()
    |> unique_constraint(:type)
  end

  def validate_telegram_config(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  def validate_telegram_config(%Ecto.Changeset{changes: %{type: type}} = changeset)
      when type != @telegram_type,
      do: changeset

  def validate_telegram_config(%Ecto.Changeset{} = changeset) do
    enabled = get_field(changeset, :enabled) || get_change(changeset, :enabled)
    config = get_field(changeset, :config) || get_change(changeset, :config) || %{}

    if enabled do
      changeset
      |> validate_config_key(config, "bot_token", "bot token")
      |> validate_config_key(config, "chat_id", "chat id")
    else
      changeset
    end
  end

  def validate_config_key(changeset, config, key, label) do
    value = Map.get(config, key) || Map.get(config, String.to_atom(key))

    if is_binary(value) and String.trim(value) != "" do
      changeset
    else
      add_error(changeset, :config, "#{label} is required when notifications are enabled")
    end
  end
end

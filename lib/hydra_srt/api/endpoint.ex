defmodule HydraSrt.Api.Endpoint do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  @source_unique_constraint :endpoints_route_id_position_type_index
  @bind_target_unique_constraint :endpoints_bind_interface_bind_address_bind_port_index

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
    # Flattened transport options (source of truth for persisted endpoint config).
    field :mode, :string
    field :interface_sys_name, :string
    field :localaddress, :string
    field :localport, :integer
    field :address, :string
    field :port, :integer
    field :host, :string
    field :latency, :integer
    field :authentication, :boolean
    field :passphrase, :string
    field :pbkeylen, :integer
    field :poll_timeout, :integer
    field :auto_reconnect, :boolean
    field :keep_listening, :boolean
    field :multicast_iface, :string
    field :bind_address_option, :string

    # Normalized bind tuple for DB uniqueness.
    field :bind_interface, :string
    field :bind_address, :string
    field :bind_port, :integer
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

  def source_type, do: "source"
  def destination_type, do: "destination"

  def source_scope(query \\ __MODULE__) do
    from(e in query, where: e.type == "source")
  end

  def destination_scope(query \\ __MODULE__) do
    from(e in query, where: e.type == "destination")
  end

  def source_changeset(endpoint, attrs) do
    endpoint
    |> cast_common(attrs)
    |> put_change(:type, "source")
    |> put_default_enabled(true)
    |> validate_required([:route_id, :position, :schema, :type])
    |> validate_inclusion(:schema, ["SRT", "UDP"])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> put_bind_target_fields()
    |> unique_constraint([:route_id, :position, :type], name: @source_unique_constraint)
    |> unique_constraint(:bind_port,
      name: @bind_target_unique_constraint,
      message: "bind target is already in use"
    )
    |> optimistic_lock(:lock_version)
  end

  def destination_changeset(endpoint, attrs) do
    endpoint
    |> cast_common(attrs)
    |> put_change(:type, "destination")
    |> put_default_enabled(false)
    |> validate_required([:route_id, :schema, :type])
    |> put_bind_target_fields()
    |> unique_constraint([:route_id, :position, :type], name: @source_unique_constraint)
    |> unique_constraint(:bind_port,
      name: @bind_target_unique_constraint,
      message: "bind target is already in use"
    )
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
      :mode,
      :interface_sys_name,
      :localaddress,
      :localport,
      :address,
      :port,
      :host,
      :latency,
      :authentication,
      :passphrase,
      :pbkeylen,
      :poll_timeout,
      :auto_reconnect,
      :keep_listening,
      :multicast_iface,
      :bind_address_option,
      :bind_interface,
      :bind_address,
      :bind_port,
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

  defp put_bind_target_fields(changeset) do
    case endpoint_bind_target(changeset) do
      %{interface: interface, address: address, port: port} ->
        changeset
        |> put_change(:bind_interface, interface)
        |> put_change(:bind_address, address)
        |> put_change(:bind_port, port)

      _ ->
        changeset
        |> put_change(:bind_interface, nil)
        |> put_change(:bind_address, nil)
        |> put_change(:bind_port, nil)
    end
  end

  defp endpoint_bind_target(changeset) do
    schema = get_field(changeset, :schema)
    type = get_field(changeset, :type)

    case {schema, type} do
      {"SRT", _} ->
        mode = get_field(changeset, :mode)

        if mode in ["listener", "rendezvous"] do
          build_target(changeset)
        else
          nil
        end

      {"UDP", "source"} ->
        build_target(changeset)

      {"UDP", "destination"} ->
        build_target(changeset)

      _ ->
        nil
    end
  end

  defp build_target(changeset) do
    port = get_field(changeset, :localport) || get_field(changeset, :port)

    if is_integer(port) do
      %{
        interface: normalize(get_field(changeset, :interface_sys_name)),
        address:
          normalize(
            first_present([
              get_field(changeset, :localaddress),
              get_field(changeset, :address),
              get_field(changeset, :host)
            ])
          ),
        port: port
      }
    else
      nil
    end
  end

  defp first_present(values) when is_list(values) do
    Enum.find(values, &present?/1)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_integer(value), do: true
  defp present?(_), do: false

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_), do: ""
end

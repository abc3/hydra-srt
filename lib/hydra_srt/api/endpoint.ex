defmodule HydraSrt.Api.Endpoint do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  @source_unique_constraint :endpoints_route_id_position_type_index
  @bind_target_unique_constraint :endpoints_bind_interface_bind_address_bind_port_index
  @ip_access_list_fields [:allowed_list, :denied_list]

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
    field :streamid, :string
    field :passphrase, :string
    field :pbkeylen, :integer
    field :poll_timeout, :integer
    field :auto_reconnect, :boolean
    field :keep_listening, :boolean
    field :multicast, :boolean, default: false
    field :multicast_iface, :string
    field :bind_address_option, :string
    field :path, :string
    field :location, :string
    field :allowed_list, :string, default: "[]"
    field :denied_list, :string, default: "[]"
    field :limit_access, :boolean, default: false

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
    |> cast_common(normalize_ip_access_attrs(attrs))
    |> put_change(:type, "source")
    |> put_default_enabled(true)
    |> put_default_ip_access_fields()
    |> put_default_ip_access_field(:multicast, false)
    |> normalize_rtmp_path_change()
    |> normalize_rtmp_location_change()
    |> validate_ip_access_lists()
    |> validate_required([:route_id, :position, :schema, :type])
    |> validate_inclusion(:schema, ["SRT", "UDP", "RTP", "RTMP"])
    |> validate_rtmp_required_fields()
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
    |> cast_common(normalize_ip_access_attrs(attrs))
    |> put_change(:type, "destination")
    |> put_default_enabled(false)
    |> put_default_ip_access_field(:multicast, false)
    |> normalize_rtmp_location_change()
    |> validate_required([:route_id, :schema, :type])
    |> validate_inclusion(:schema, ["SRT", "UDP", "RTMP"])
    |> validate_rtmp_required_fields()
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
      :streamid,
      :passphrase,
      :pbkeylen,
      :poll_timeout,
      :auto_reconnect,
      :keep_listening,
      :multicast,
      :multicast_iface,
      :bind_address_option,
      :path,
      :location,
      :allowed_list,
      :denied_list,
      :limit_access,
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

  def normalize_rtmp_path_change(changeset) do
    update_change(changeset, :path, &normalize_rtmp_path/1)
  end

  def normalize_rtmp_path(path) when is_binary(path) do
    path = String.trim(path)

    cond do
      path == "" -> nil
      String.starts_with?(path, "/") -> path
      true -> "/" <> path
    end
  end

  def normalize_rtmp_path(path), do: path

  def normalize_rtmp_location_change(changeset) do
    update_change(changeset, :location, &normalize_optional_string/1)
  end

  def normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def normalize_optional_string(value), do: value

  def validate_rtmp_required_fields(changeset) do
    case {get_field(changeset, :schema), get_field(changeset, :type)} do
      {"RTMP", "source"} -> validate_required(changeset, [:path])
      {"RTMP", "destination"} -> validate_required(changeset, [:location])
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

      {"RTP", "source"} ->
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

  @doc false
  @spec normalize_ip_access_attrs(term()) :: term()
  def normalize_ip_access_attrs(attrs) when is_map(attrs) do
    Enum.reduce(@ip_access_list_fields, attrs, fn field, acc ->
      encode_ip_access_attr(acc, field)
    end)
  end

  def normalize_ip_access_attrs(attrs), do: attrs

  @doc false
  @spec decode_ip_access_list(nil | binary() | list()) :: [binary()]
  def decode_ip_access_list(nil), do: []

  def decode_ip_access_list(value) when is_list(value) do
    normalize_ip_access_list(value)
  end

  def decode_ip_access_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> normalize_ip_access_list(list)
      _ -> []
    end
  end

  @doc false
  @spec valid_ip_access_entry?(binary()) :: boolean()
  def valid_ip_access_entry?(entry) when is_binary(entry) do
    normalized = String.trim(entry)

    case String.split(normalized, "/", parts: 2) do
      [ip] ->
        parse_ip(ip) != :error

      [ip, prefix] ->
        valid_cidr_entry?(ip, prefix)
    end
  end

  def valid_ip_access_entry?(_), do: false

  @spec encode_ip_access_attr(map(), atom()) :: map()
  def encode_ip_access_attr(attrs, field) when is_map(attrs) and is_atom(field) do
    string_key = Atom.to_string(field)

    cond do
      Map.has_key?(attrs, field) ->
        Map.update!(attrs, field, &encode_ip_access_value/1)

      Map.has_key?(attrs, string_key) ->
        Map.update!(attrs, string_key, &encode_ip_access_value/1)

      true ->
        attrs
    end
  end

  @spec encode_ip_access_value(term()) :: term()
  def encode_ip_access_value(value) when is_list(value) do
    value
    |> normalize_ip_access_list()
    |> Jason.encode!()
  end

  def encode_ip_access_value(value) when is_binary(value), do: value
  def encode_ip_access_value(nil), do: "[]"
  def encode_ip_access_value(value), do: value

  @spec put_default_ip_access_fields(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def put_default_ip_access_fields(changeset) do
    changeset
    |> put_default_ip_access_field(:allowed_list, "[]")
    |> put_default_ip_access_field(:denied_list, "[]")
    |> put_default_ip_access_field(:limit_access, false)
  end

  @spec put_default_ip_access_field(Ecto.Changeset.t(), atom(), term()) :: Ecto.Changeset.t()
  def put_default_ip_access_field(changeset, field, default) do
    case fetch_field(changeset, field) do
      {_, nil} -> put_change(changeset, field, default)
      _ -> changeset
    end
  end

  @spec validate_ip_access_lists(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_ip_access_lists(changeset) do
    Enum.reduce(@ip_access_list_fields, changeset, fn field, acc ->
      validate_change(acc, field, &validate_ip_access_list/2)
    end)
  end

  @spec validate_ip_access_list(atom(), term()) :: keyword()
  def validate_ip_access_list(field, value) do
    case Jason.decode(value || "[]") do
      {:ok, entries} when is_list(entries) ->
        invalid_entries =
          entries
          |> normalize_ip_access_list()
          |> Enum.reject(&valid_ip_access_entry?/1)

        if invalid_entries == [] do
          []
        else
          [{field, "must contain only IP addresses or CIDR ranges"}]
        end

      _ ->
        [{field, "must be a JSON list"}]
    end
  end

  @spec normalize_ip_access_list(list()) :: [binary()]
  def normalize_ip_access_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @spec valid_cidr_entry?(binary(), binary()) :: boolean()
  def valid_cidr_entry?(ip, prefix) do
    with {:ok, tuple} <- parse_ip(ip),
         {prefix_number, ""} <- Integer.parse(prefix),
         true <- valid_prefix?(tuple, prefix_number) do
      true
    else
      _ -> false
    end
  end

  @spec parse_ip(binary()) :: {:ok, tuple()} | :error
  def parse_ip(value) when is_binary(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> :error
    end
  end

  @spec valid_prefix?(tuple(), integer()) :: boolean()
  def valid_prefix?({_, _, _, _}, prefix), do: prefix >= 0 and prefix <= 32
  def valid_prefix?({_, _, _, _, _, _, _, _}, prefix), do: prefix >= 0 and prefix <= 128
  def valid_prefix?(_, _), do: false
end

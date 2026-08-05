defmodule HydraSrt.Api.Endpoint do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  @source_unique_constraint :endpoints_route_id_position_type_index
  # Two partial indexes, because what pins an endpoint to a socket differs: an endpoint that
  # names an interface is bound to that interface's address at runtime, whichever address the
  # row happens to carry, so interface + port decides. Everything else is keyed on the
  # address it actually binds.
  @interface_bind_target_constraint :endpoints_bind_interface_bind_port_index
  @address_bind_target_constraint :endpoints_bind_address_bind_port_index
  @bind_target_in_use_message "bind target is already in use"
  # exqlite reports UNIQUE failures via Ecto's default derived name
  # (`table_column_index`), not the migration's custom partial-index name.
  @ndi_sender_name_key_unique_constraint :endpoints_ndi_sender_name_key_index
  @ip_access_list_fields [:allowed_list, :denied_list]

  @ndi_selection_modes ~w(discovery_name direct_address)
  @ndi_media_policies ~w(
    video_and_audio_required
    video_required_audio_optional
    video_only
    audio_only
  )
  @ndi_bandwidths ~w(highest audio_only)
  @ndi_color_formats ~w(uyvy-bgra fastest best bgrx-bgra rgbx-rgba uyvy-rgba)
  # Mirrors hydra-plan `NdiTimestampMode` serde renames exactly.
  @ndi_timestamp_modes ~w(auto receive-time timecode timestamp receive-time-vs-timestamp)
  @ndi_timeout_ms_min 1000
  @ndi_timeout_ms_max 60_000
  @ndi_max_queue_length_min 1
  @ndi_max_queue_length_max 64
  @source_schemas ~w(SRT UDP RTP RTMP NDI)
  @destination_schemas ~w(SRT UDP RTMP NDI)

  @ndi_fields [
    :ndi_source_name,
    :ndi_source_address,
    :ndi_selection_mode,
    :ndi_observed_address_snapshot,
    :ndi_observed_name_snapshot,
    :ndi_selection_observed_at,
    :ndi_receiver_name,
    :ndi_media_policy,
    :ndi_bandwidth,
    :ndi_color_format,
    :ndi_timestamp_mode,
    :ndi_connect_timeout_ms,
    :ndi_receive_timeout_ms,
    :ndi_track_discovery_timeout_ms,
    :ndi_max_queue_length,
    :ndi_sender_name,
    :ndi_sender_name_key
  ]

  # Source-direction columns; destinations force these nil (shared media_policy kept).
  @ndi_source_direction_fields [
    :ndi_source_name,
    :ndi_source_address,
    :ndi_selection_mode,
    :ndi_observed_address_snapshot,
    :ndi_observed_name_snapshot,
    :ndi_selection_observed_at,
    :ndi_receiver_name,
    :ndi_bandwidth,
    :ndi_color_format,
    :ndi_timestamp_mode,
    :ndi_connect_timeout_ms,
    :ndi_receive_timeout_ms,
    :ndi_track_discovery_timeout_ms,
    :ndi_max_queue_length
  ]

  # Destination-direction columns; sources force these nil.
  @ndi_destination_direction_fields [
    :ndi_sender_name,
    :ndi_sender_name_key
  ]

  @ndi_cast_fields [
    :ndi_source_name,
    :ndi_source_address,
    :ndi_selection_mode,
    :ndi_observed_address_snapshot,
    :ndi_observed_name_snapshot,
    :ndi_selection_observed_at,
    :ndi_receiver_name,
    :ndi_media_policy,
    :ndi_bandwidth,
    :ndi_color_format,
    :ndi_timestamp_mode,
    :ndi_connect_timeout_ms,
    :ndi_receive_timeout_ms,
    :ndi_track_discovery_timeout_ms,
    :ndi_max_queue_length,
    :ndi_sender_name
  ]

  @type t :: %__MODULE__{}

  @type ndi_field ::
          :ndi_source_name
          | :ndi_source_address
          | :ndi_selection_mode
          | :ndi_observed_address_snapshot
          | :ndi_observed_name_snapshot
          | :ndi_selection_observed_at
          | :ndi_receiver_name
          | :ndi_media_policy
          | :ndi_bandwidth
          | :ndi_color_format
          | :ndi_timestamp_mode
          | :ndi_connect_timeout_ms
          | :ndi_receive_timeout_ms
          | :ndi_track_discovery_timeout_ms
          | :ndi_max_queue_length
          | :ndi_sender_name
          | :ndi_sender_name_key

  @type ndi_ip_family :: :ipv4 | :ipv6

  @type bind_target :: %{
          interface: String.t(),
          address: String.t(),
          port: integer()
        }

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

    # NDI operator intent (nullable; cleared for non-NDI schemas).
    field :ndi_source_name, :string
    field :ndi_source_address, :string
    field :ndi_selection_mode, :string
    field :ndi_observed_address_snapshot, :string
    field :ndi_observed_name_snapshot, :string
    field :ndi_selection_observed_at, :utc_datetime
    field :ndi_receiver_name, :string
    field :ndi_media_policy, :string
    field :ndi_bandwidth, :string
    field :ndi_color_format, :string
    field :ndi_timestamp_mode, :string
    field :ndi_connect_timeout_ms, :integer
    field :ndi_receive_timeout_ms, :integer
    field :ndi_track_discovery_timeout_ms, :integer
    field :ndi_max_queue_length, :integer
    field :ndi_sender_name, :string
    # Server-derived collision key; never cast from input or serialized.
    field :ndi_sender_name_key, :string

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

  @spec source_changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
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
    |> validate_inclusion(:schema, @source_schemas)
    |> validate_rtmp_required_fields()
    |> validate_ndi_fields()
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> put_bind_target_fields()
    |> unique_constraint([:route_id, :position, :type], name: @source_unique_constraint)
    |> unique_constraint(:bind_port,
      name: @interface_bind_target_constraint,
      message: @bind_target_in_use_message
    )
    |> unique_constraint(:bind_port,
      name: @address_bind_target_constraint,
      message: @bind_target_in_use_message
    )
    |> optimistic_lock(:lock_version)
  end

  @spec destination_changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def destination_changeset(endpoint, attrs) do
    endpoint
    |> cast_common(normalize_ip_access_attrs(attrs))
    |> put_change(:type, "destination")
    |> put_default_enabled(false)
    |> put_default_ip_access_field(:multicast, false)
    |> normalize_rtmp_location_change()
    |> validate_required([:route_id, :schema, :type])
    |> validate_inclusion(:schema, @destination_schemas)
    |> validate_rtmp_required_fields()
    |> validate_ndi_fields()
    |> put_bind_target_fields()
    |> unique_constraint([:route_id, :position, :type], name: @source_unique_constraint)
    |> unique_constraint(:bind_port,
      name: @interface_bind_target_constraint,
      message: @bind_target_in_use_message
    )
    |> unique_constraint(:bind_port,
      name: @address_bind_target_constraint,
      message: @bind_target_in_use_message
    )
    |> unique_constraint(:ndi_sender_name_key,
      name: @ndi_sender_name_key_unique_constraint,
      message: "NDI sender name is already in use by an enabled destination"
    )
    |> optimistic_lock(:lock_version)
  end

  @spec cast_common(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def cast_common(endpoint, attrs) do
    cast(
      endpoint,
      attrs,
      [
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
      ] ++ @ndi_cast_fields
    )
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

  @spec endpoint_bind_target(Ecto.Changeset.t()) :: bind_target() | nil
  def endpoint_bind_target(changeset) do
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

      {"NDI", _} ->
        nil

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

  @spec ndi_fields() :: [ndi_field()]
  def ndi_fields, do: @ndi_fields

  @spec ndi_selection_modes() :: [String.t()]
  def ndi_selection_modes, do: @ndi_selection_modes

  @spec ndi_media_policies() :: [String.t()]
  def ndi_media_policies, do: @ndi_media_policies

  @spec ndi_bandwidths() :: [String.t()]
  def ndi_bandwidths, do: @ndi_bandwidths

  @spec ndi_color_formats() :: [String.t()]
  def ndi_color_formats, do: @ndi_color_formats

  @spec ndi_timestamp_modes() :: [String.t()]
  def ndi_timestamp_modes, do: @ndi_timestamp_modes

  @spec ndi_timeout_ms_min() :: pos_integer()
  def ndi_timeout_ms_min, do: @ndi_timeout_ms_min

  @spec ndi_timeout_ms_max() :: pos_integer()
  def ndi_timeout_ms_max, do: @ndi_timeout_ms_max

  @spec ndi_max_queue_length_min() :: pos_integer()
  def ndi_max_queue_length_min, do: @ndi_max_queue_length_min

  @spec ndi_max_queue_length_max() :: pos_integer()
  def ndi_max_queue_length_max, do: @ndi_max_queue_length_max

  @spec source_schemas() :: [String.t()]
  def source_schemas, do: @source_schemas

  @spec destination_schemas() :: [String.t()]
  def destination_schemas, do: @destination_schemas

  @spec validate_ndi_fields(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_ndi_fields(changeset) do
    case get_field(changeset, :schema) do
      "NDI" ->
        changeset
        |> normalize_ndi_string_fields()
        |> clear_opposite_ndi_direction_fields()
        |> validate_ndi_shared_options()
        |> validate_ndi_by_type()

      _ ->
        clear_ndi_fields(changeset)
    end
  end

  @spec clear_ndi_fields(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def clear_ndi_fields(changeset) do
    clear_ndi_field_list(changeset, @ndi_fields)
  end

  @spec clear_ndi_field_list(Ecto.Changeset.t(), [ndi_field()]) :: Ecto.Changeset.t()
  def clear_ndi_field_list(changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      put_change(acc, field, nil)
    end)
  end

  @spec clear_opposite_ndi_direction_fields(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def clear_opposite_ndi_direction_fields(changeset) do
    case get_field(changeset, :type) do
      "source" ->
        clear_ndi_field_list(changeset, @ndi_destination_direction_fields)

      "destination" ->
        clear_ndi_field_list(changeset, @ndi_source_direction_fields)

      _ ->
        changeset
    end
  end

  @spec normalize_ndi_string_fields(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def normalize_ndi_string_fields(changeset) do
    Enum.reduce(
      [
        :ndi_source_name,
        :ndi_source_address,
        :ndi_selection_mode,
        :ndi_observed_address_snapshot,
        :ndi_observed_name_snapshot,
        :ndi_receiver_name,
        :ndi_media_policy,
        :ndi_bandwidth,
        :ndi_color_format,
        :ndi_timestamp_mode,
        :ndi_sender_name
      ],
      changeset,
      fn field, acc ->
        update_change(acc, field, &normalize_optional_string/1)
      end
    )
  end

  @spec validate_ndi_shared_options(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_ndi_shared_options(changeset) do
    changeset
    |> validate_inclusion(:ndi_media_policy, @ndi_media_policies)
    |> validate_inclusion(:ndi_bandwidth, @ndi_bandwidths)
    |> validate_inclusion(:ndi_color_format, @ndi_color_formats)
    |> validate_inclusion(:ndi_timestamp_mode, @ndi_timestamp_modes)
    |> validate_number(:ndi_connect_timeout_ms,
      greater_than_or_equal_to: @ndi_timeout_ms_min,
      less_than_or_equal_to: @ndi_timeout_ms_max
    )
    |> validate_number(:ndi_receive_timeout_ms,
      greater_than_or_equal_to: @ndi_timeout_ms_min,
      less_than_or_equal_to: @ndi_timeout_ms_max
    )
    |> validate_number(:ndi_track_discovery_timeout_ms,
      greater_than_or_equal_to: @ndi_timeout_ms_min,
      less_than_or_equal_to: @ndi_timeout_ms_max
    )
    |> validate_number(:ndi_max_queue_length,
      greater_than_or_equal_to: @ndi_max_queue_length_min,
      less_than_or_equal_to: @ndi_max_queue_length_max
    )
  end

  @spec validate_ndi_by_type(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_ndi_by_type(changeset) do
    case get_field(changeset, :type) do
      "source" ->
        validate_ndi_source(changeset)

      "destination" ->
        validate_ndi_destination(changeset)

      _ ->
        changeset
    end
  end

  @spec validate_ndi_source(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_ndi_source(changeset) do
    changeset
    |> validate_required([:ndi_selection_mode])
    |> validate_inclusion(:ndi_selection_mode, @ndi_selection_modes)
    |> validate_ndi_source_selection()
  end

  @spec validate_ndi_source_selection(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_ndi_source_selection(changeset) do
    mode = get_field(changeset, :ndi_selection_mode)
    name = get_field(changeset, :ndi_source_name)
    address = get_field(changeset, :ndi_source_address)
    name_present? = present?(name)
    address_present? = present?(address)

    cond do
      mode == "discovery_name" and name_present? and not address_present? ->
        changeset

      mode == "direct_address" and address_present? and not name_present? ->
        validate_ndi_source_address_field(changeset)

      mode == "discovery_name" and address_present? ->
        add_error(
          changeset,
          :ndi_source_address,
          "must be blank when selection mode is discovery_name"
        )

      mode == "direct_address" and name_present? ->
        add_error(
          changeset,
          :ndi_source_name,
          "must be blank when selection mode is direct_address"
        )

      mode == "discovery_name" ->
        add_error(changeset, :ndi_source_name, "can't be blank")

      mode == "direct_address" ->
        add_error(changeset, :ndi_source_address, "can't be blank")

      name_present? and address_present? ->
        changeset
        |> add_error(:ndi_source_name, "must not be set together with ndi_source_address")
        |> add_error(:ndi_source_address, "must not be set together with ndi_source_name")

      true ->
        changeset
    end
  end

  @spec validate_ndi_source_address_field(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_ndi_source_address_field(changeset) do
    validate_change(changeset, :ndi_source_address, fn :ndi_source_address, value ->
      if valid_ndi_source_address?(value) do
        []
      else
        [
          {:ndi_source_address,
           "must be a literal IPv4 host:port or [IPv6]:port address (DNS names are not allowed)"}
        ]
      end
    end)
  end

  @spec validate_ndi_destination(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_ndi_destination(changeset) do
    name = get_field(changeset, :ndi_sender_name)

    cond do
      present?(name) ->
        put_change(changeset, :ndi_sender_name_key, normalize_ndi_sender_name_key(name))

      true ->
        changeset
        |> put_change(:ndi_sender_name_key, nil)
        |> add_error(:ndi_sender_name, "can't be blank")
    end
  end

  @spec normalize_ndi_sender_name_key(String.t()) :: String.t()
  def normalize_ndi_sender_name_key(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
    |> String.normalize(:nfc)
    |> then(fn normalized ->
      normalized
      |> String.to_charlist()
      |> :string.casefold()
      |> IO.chardata_to_string()
    end)
  end

  @spec valid_ndi_source_address?(term()) :: boolean()
  def valid_ndi_source_address?(value) when is_binary(value) do
    match?({:ok, _address, _port}, parse_ndi_source_address(value))
  end

  def valid_ndi_source_address?(_), do: false

  @spec parse_ndi_source_address(String.t()) ::
          {:ok, :inet.ip_address(), pos_integer()} | :error
  def parse_ndi_source_address("[" <> rest) do
    case String.split(rest, "]:", parts: 2) do
      [ip, port_str] ->
        parse_ndi_ip_and_port(ip, port_str, :ipv6)

      _ ->
        :error
    end
  end

  def parse_ndi_source_address(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [ip, port_str] ->
        parse_ndi_ip_and_port(ip, port_str, :ipv4)

      _ ->
        :error
    end
  end

  @spec parse_ndi_ip_and_port(String.t(), String.t(), ndi_ip_family()) ::
          {:ok, :inet.ip_address(), pos_integer()} | :error
  def parse_ndi_ip_and_port(ip, port_str, family) do
    with {:ok, address} <- parse_ip(ip),
         true <- ndi_address_family_match?(address, family),
         {port, ""} <- Integer.parse(port_str),
         true <- port >= 1 and port <= 65_535 do
      {:ok, address, port}
    else
      _ -> :error
    end
  end

  @spec ndi_address_family_match?(term(), ndi_ip_family()) :: boolean()
  def ndi_address_family_match?({_, _, _, _}, :ipv4), do: true
  def ndi_address_family_match?({_, _, _, _, _, _, _, _}, :ipv6), do: true
  def ndi_address_family_match?(_, _), do: false
end

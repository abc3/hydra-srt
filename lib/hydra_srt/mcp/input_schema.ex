defmodule HydraSrt.Mcp.InputSchema do
  @moduledoc false

  alias HydraSrt.Api.Endpoint

  # Observed-identity / derived-key columns are never accepted via MCP.
  @forbidden_ndi_keys ~w(
    ndi_sender_name_key
    ndi_observed_address_snapshot
    ndi_observed_name_snapshot
    ndi_selection_observed_at
  )

  # Raw GStreamer / native props must not enter through MCP.
  @forbidden_raw_keys ~w(props element_type legacy processing_profiles)

  # Shared source/destination attribute fields (types + descriptions folded into a map).
  @common_endpoint_fields [
    {"name", :string, "Endpoint display name"},
    {"alias", :string, "Endpoint alias"},
    {"enabled", :boolean, "Whether the endpoint is enabled"},
    {"position", :integer, "Source position (sources only)"},
    {"mode", :string, "Transport mode (for example SRT listener/caller)"},
    {"interface_sys_name", :string, "System interface name"},
    {"localaddress", :string, "Local bind address"},
    {"localport", :integer, "Local bind port"},
    {"address", :string, "Remote or bind address"},
    {"port", :integer, "Port"},
    {"host", :string, "Host"},
    {"latency", :integer, "Latency ms"},
    {"authentication", :boolean, "SRT authentication enabled"},
    {"streamid", :string, "SRT stream id"},
    {"passphrase", :string, "SRT passphrase"},
    {"pbkeylen", :integer, "SRT passphrase key length"},
    {"poll_timeout", :integer, "Poll timeout"},
    {"auto_reconnect", :boolean, "Auto reconnect"},
    {"keep_listening", :boolean, "Keep listening"},
    {"multicast", :boolean, "Multicast enabled"},
    {"multicast_iface", :string, "Multicast interface"},
    {"bind_address_option", :string, "Bind address option"},
    {"path", :string, "RTMP path"},
    {"location", :string, "RTMP location"},
    {"allowed_list", :string_array, "Allowed IP access list (CIDR entries)"},
    {"denied_list", :string_array, "Denied IP access list (CIDR entries)"},
    {"limit_access", :boolean, "Limit IP access"}
  ]

  @ndi_source_enum_fields [
    {"ndi_selection_mode", :ndi_selection_modes,
     "NDI source selection mode (discovery_name XOR direct_address locator)"},
    {"ndi_media_policy", :ndi_media_policies, "NDI required-track media policy"},
    {"ndi_bandwidth", :ndi_bandwidths, "NDI receive bandwidth mode"},
    {"ndi_color_format", :ndi_color_formats, "NDI color format"},
    {"ndi_timestamp_mode", :ndi_timestamp_modes, "NDI timestamp mode (optional)"}
  ]

  @ndi_source_timeout_fields [
    {"ndi_connect_timeout_ms", "connect"},
    {"ndi_receive_timeout_ms", "receive"},
    {"ndi_track_discovery_timeout_ms", "track discovery"}
  ]

  @spec to_hermes(map()) :: map()
  def to_hermes(%{"type" => "object", "properties" => properties} = schema)
      when is_map(properties) do
    required = Map.get(schema, "required", [])

    Map.new(properties, fn {key, property} ->
      {key, to_hermes_field(property, key in required)}
    end)
  end

  def to_hermes(_schema), do: %{}

  @spec to_hermes_field(map() | term(), boolean()) :: term()
  def to_hermes_field(property, required?) when is_map(property) do
    type =
      case property do
        %{"type" => "string", "enum" => values} when is_list(values) ->
          {:enum, values, [type: :string]}

        %{"type" => "string"} ->
          :string

        %{"type" => "integer"} ->
          :integer

        %{"type" => "boolean"} ->
          :boolean

        %{"type" => "array", "items" => %{"type" => "string"}} ->
          {:list, :string}

        # Peri represents a nested object as a plain field map; an empty object
        # (description only, no properties) stays free-form.
        %{"type" => "object"} = nested ->
          case to_hermes(nested) do
            nested_fields when map_size(nested_fields) == 0 -> :any
            nested_fields -> nested_fields
          end

        _ ->
          :any
      end

    if required?, do: {:required, type}, else: type
  end

  def to_hermes_field(_property, required?) do
    if required?, do: {:required, :any}, else: :any
  end

  @spec string_prop(String.t()) :: map()
  def string_prop(description) when is_binary(description) do
    %{"type" => "string", "description" => description}
  end

  @spec enum_prop([String.t()], String.t()) :: map()
  def enum_prop(values, description) when is_list(values) and is_binary(description) do
    %{"type" => "string", "enum" => values, "description" => description}
  end

  @spec integer_prop(String.t()) :: map()
  def integer_prop(description) when is_binary(description) do
    %{"type" => "integer", "description" => description}
  end

  @spec integer_prop(String.t(), keyword()) :: map()
  def integer_prop(description, opts) when is_binary(description) and is_list(opts) do
    prop = %{"type" => "integer", "description" => description}

    prop
    |> put_optional_number("minimum", Keyword.get(opts, :minimum))
    |> put_optional_number("maximum", Keyword.get(opts, :maximum))
  end

  @spec boolean_prop(String.t()) :: map()
  def boolean_prop(description) when is_binary(description) do
    %{"type" => "boolean", "description" => description}
  end

  @spec array_string_prop(String.t()) :: map()
  def array_string_prop(description) when is_binary(description) do
    %{"type" => "array", "items" => %{"type" => "string"}, "description" => description}
  end

  @spec typed_prop(:string | :integer | :boolean | :string_array, String.t()) :: map()
  def typed_prop(:string, description) when is_binary(description), do: string_prop(description)

  def typed_prop(:integer, description) when is_binary(description),
    do: integer_prop(description)

  def typed_prop(:boolean, description) when is_binary(description),
    do: boolean_prop(description)

  def typed_prop(:string_array, description) when is_binary(description),
    do: array_string_prop(description)

  @spec properties_from_fields([{String.t(), atom(), String.t()}]) :: %{String.t() => map()}
  def properties_from_fields(fields) when is_list(fields) do
    Map.new(fields, fn {name, type, description} ->
      {name, typed_prop(type, description)}
    end)
  end

  @spec put_optional_number(map(), String.t(), integer() | nil) :: map()
  def put_optional_number(prop, _key, nil) when is_map(prop), do: prop

  def put_optional_number(prop, key, value)
      when is_map(prop) and is_binary(key) and is_integer(value) do
    Map.put(prop, key, value)
  end

  @spec ndi_timeout_integer_prop(String.t()) :: map()
  def ndi_timeout_integer_prop(description) when is_binary(description) do
    integer_prop(description,
      minimum: Endpoint.ndi_timeout_ms_min(),
      maximum: Endpoint.ndi_timeout_ms_max()
    )
  end

  @spec ndi_max_queue_length_prop() :: map()
  def ndi_max_queue_length_prop do
    integer_prop(
      "NDI max queue length (#{Endpoint.ndi_max_queue_length_min()}..#{Endpoint.ndi_max_queue_length_max()})",
      minimum: Endpoint.ndi_max_queue_length_min(),
      maximum: Endpoint.ndi_max_queue_length_max()
    )
  end

  @spec ndi_allowlist(atom()) :: [String.t()]
  def ndi_allowlist(:ndi_selection_modes), do: Endpoint.ndi_selection_modes()
  def ndi_allowlist(:ndi_media_policies), do: Endpoint.ndi_media_policies()
  def ndi_allowlist(:ndi_bandwidths), do: Endpoint.ndi_bandwidths()
  def ndi_allowlist(:ndi_color_formats), do: Endpoint.ndi_color_formats()
  def ndi_allowlist(:ndi_timestamp_modes), do: Endpoint.ndi_timestamp_modes()

  @spec ndi_source_field_properties() :: %{String.t() => map()}
  def ndi_source_field_properties do
    timeout_range = "#{Endpoint.ndi_timeout_ms_min()}..#{Endpoint.ndi_timeout_ms_max()}"

    enums =
      Map.new(@ndi_source_enum_fields, fn {name, allowlist, description} ->
        {name, enum_prop(ndi_allowlist(allowlist), description)}
      end)

    timeouts =
      Map.new(@ndi_source_timeout_fields, fn {name, label} ->
        {name, ndi_timeout_integer_prop("NDI #{label} timeout ms (#{timeout_range})")}
      end)

    %{
      "ndi_source_name" =>
        string_prop("NDI discovery source name (required when selection_mode is discovery_name)"),
      "ndi_source_address" =>
        string_prop(
          "NDI literal ip:port (IPv4 or [IPv6]:port; required when selection_mode is direct_address)"
        ),
      "ndi_receiver_name" => string_prop("Optional NDI receiver display name"),
      "ndi_max_queue_length" => ndi_max_queue_length_prop()
    }
    |> Map.merge(enums)
    |> Map.merge(timeouts)
  end

  @spec ndi_destination_field_properties() :: %{String.t() => map()}
  def ndi_destination_field_properties do
    %{
      "ndi_sender_name" => string_prop("NDI sender name (required for NDI destinations)"),
      "ndi_media_policy" =>
        enum_prop(Endpoint.ndi_media_policies(), "NDI required-track media policy")
    }
  end

  @spec common_endpoint_field_properties() :: %{String.t() => map()}
  def common_endpoint_field_properties do
    properties_from_fields(@common_endpoint_fields)
  end

  @spec source_attributes_schema() :: map()
  def source_attributes_schema do
    properties =
      common_endpoint_field_properties()
      |> Map.merge(ndi_source_field_properties())
      |> Map.put(
        "schema",
        enum_prop(Endpoint.source_schemas(), "Source protocol schema")
      )

    %{
      "type" => "object",
      "description" =>
        "Source attributes. NDI uses typed ndi_* fields only (no raw GStreamer props).",
      "properties" => properties
    }
  end

  @spec destination_attributes_schema() :: map()
  def destination_attributes_schema do
    properties =
      common_endpoint_field_properties()
      |> Map.merge(ndi_destination_field_properties())
      |> Map.put(
        "schema",
        enum_prop(Endpoint.destination_schemas(), "Destination protocol schema")
      )

    %{
      "type" => "object",
      "description" =>
        "Destination attributes. NDI uses typed ndi_* fields only (no raw GStreamer props).",
      "properties" => properties
    }
  end

  @spec sanitize_source_attrs(map()) :: map()
  def sanitize_source_attrs(attrs) when is_map(attrs) do
    attrs
    |> drop_forbidden_keys()
    |> drop_keys(["ndi_sender_name"])
  end

  @spec sanitize_destination_attrs(map()) :: map()
  def sanitize_destination_attrs(attrs) when is_map(attrs) do
    attrs
    |> drop_forbidden_keys()
    |> drop_keys([
      "ndi_source_name",
      "ndi_source_address",
      "ndi_selection_mode",
      "ndi_receiver_name",
      "ndi_bandwidth",
      "ndi_color_format",
      "ndi_timestamp_mode",
      "ndi_connect_timeout_ms",
      "ndi_receive_timeout_ms",
      "ndi_track_discovery_timeout_ms",
      "ndi_max_queue_length"
    ])
  end

  @spec drop_forbidden_keys(map()) :: map()
  def drop_forbidden_keys(attrs) when is_map(attrs) do
    drop_keys(attrs, @forbidden_ndi_keys ++ @forbidden_raw_keys)
  end

  @spec drop_keys(map(), [String.t()]) :: map()
  def drop_keys(attrs, keys) when is_map(attrs) and is_list(keys) do
    Enum.reduce(keys, attrs, fn key, acc ->
      acc
      |> Map.delete(key)
      |> maybe_delete_existing_atom_key(key)
    end)
  end

  @spec maybe_delete_existing_atom_key(map(), String.t()) :: map()
  def maybe_delete_existing_atom_key(attrs, key) when is_map(attrs) and is_binary(key) do
    case existing_atom(key) do
      {:ok, atom_key} -> Map.delete(attrs, atom_key)
      :error -> attrs
    end
  end

  @spec existing_atom(String.t()) :: {:ok, atom()} | :error
  def existing_atom(key) when is_binary(key) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> :error
  end
end

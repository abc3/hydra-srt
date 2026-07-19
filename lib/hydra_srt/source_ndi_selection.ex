defmodule HydraSrt.SourceNdiSelection do
  @moduledoc """
  Resolves a transient NDI discovery selection token into persisted source fields.

  MCP and other changeset callers persist intent fields directly and never pass
  `selection_token`. Transient tokens are resolved here, then stripped before
  the shared `Endpoint.source_changeset/2` path.
  """

  alias HydraSrt.Ndi.Capabilities

  @type attrs :: %{optional(String.t()) => term()}
  @type error_result :: {:error, String.t(), String.t(), map()}

  @spec apply_rest_selection(attrs(), String.t(), DateTime.t()) ::
          {:ok, attrs()} | error_result()
  def apply_rest_selection(attrs, principal, now \\ DateTime.utc_now())

  def apply_rest_selection(attrs, principal, now)
      when is_map(attrs) and is_binary(principal) and is_struct(now, DateTime) do
    attrs = stringify_keys(attrs)

    if ndi_source?(attrs) do
      resolve_ndi_selection(attrs, principal, now)
    else
      {:ok, Map.delete(attrs, "selection_token")}
    end
  end

  @spec resolve_ndi_selection(attrs(), String.t(), DateTime.t()) ::
          {:ok, attrs()} | error_result()
  def resolve_ndi_selection(attrs, principal, now)
      when is_map(attrs) and is_binary(principal) and is_struct(now, DateTime) do
    mode = attrs["ndi_selection_mode"]
    token = blank_to_nil(attrs["selection_token"])

    cond do
      mode == "discovery_name" and is_binary(token) ->
        resolve_discovery_token(attrs, token, principal, now)

      mode == "discovery_name" ->
        {:ok, Map.delete(attrs, "selection_token")}

      mode == "direct_address" ->
        {:ok, apply_direct_address_snapshot(attrs, now)}

      true ->
        {:ok, Map.delete(attrs, "selection_token")}
    end
  end

  @spec resolve_discovery_token(attrs(), String.t(), String.t(), DateTime.t()) ::
          {:ok, attrs()} | error_result()
  def resolve_discovery_token(attrs, token, principal, now)
      when is_map(attrs) and is_binary(token) and is_binary(principal) and
             is_struct(now, DateTime) do
    case Capabilities.resolve_selection_token(token, principal, now) do
      {:ok, payload} ->
        apply_discovery_payload(attrs, payload, now)

      {:error, code, message} ->
        {:error, code, message, %{"selection_token" => [message]}}
    end
  end

  @spec apply_discovery_payload(attrs(), map(), DateTime.t()) ::
          {:ok, attrs()} | error_result()
  def apply_discovery_payload(attrs, payload, now)
      when is_map(attrs) and is_map(payload) and is_struct(now, DateTime) do
    name = payload[:name] || payload["name"]
    address = payload[:url_address] || payload["url_address"]
    requested_name = blank_to_nil(attrs["ndi_source_name"])

    cond do
      not is_binary(name) or name == "" ->
        {:error, "NDI_DISCOVERY_UNAVAILABLE", "Selection token payload is missing a source name",
         %{"selection_token" => ["invalid selection"]}}

      is_binary(requested_name) and requested_name != name ->
        {:error, "NDI_DISCOVERY_UNAVAILABLE", "Selection token does not match ndi_source_name",
         %{
           "selection_token" => ["does not match ndi_source_name"],
           "ndi_source_name" => ["does not match selection token"]
         }}

      true ->
        observed_at = DateTime.truncate(now, :second)

        attrs =
          attrs
          |> Map.delete("selection_token")
          |> Map.put("ndi_selection_mode", "discovery_name")
          |> Map.put("ndi_source_name", name)
          |> Map.put("ndi_source_address", nil)
          |> Map.put("ndi_observed_address_snapshot", blank_to_nil(address))
          |> Map.put("ndi_observed_name_snapshot", nil)
          |> Map.put("ndi_selection_observed_at", observed_at)

        {:ok, attrs}
    end
  end

  @spec apply_direct_address_snapshot(attrs(), DateTime.t()) :: attrs()
  def apply_direct_address_snapshot(attrs, now)
      when is_map(attrs) and is_struct(now, DateTime) do
    observed_name = blank_to_nil(attrs["ndi_observed_name_snapshot"])

    attrs =
      attrs
      |> Map.delete("selection_token")
      |> Map.put("ndi_source_name", nil)
      |> Map.put("ndi_observed_address_snapshot", nil)

    case observed_name do
      name when is_binary(name) ->
        attrs
        |> Map.put("ndi_observed_name_snapshot", name)
        |> Map.put("ndi_selection_observed_at", DateTime.truncate(now, :second))

      nil ->
        # Leave snapshot keys absent so Ecto cast does not wipe persisted values.
        attrs
        |> Map.delete("ndi_observed_name_snapshot")
        |> Map.delete("ndi_selection_observed_at")
    end
  end

  @spec ndi_source?(attrs()) :: boolean()
  def ndi_source?(attrs) when is_map(attrs) do
    schema = attrs["schema"] || attrs[:schema]
    is_binary(schema) and String.upcase(schema) == "NDI"
  end

  @spec stringify_keys(map()) :: attrs()
  def stringify_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} when is_binary(key) -> {key, value}
      {key, value} -> {to_string(key), value}
    end)
  end

  @spec blank_to_nil(term()) :: String.t() | nil
  def blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def blank_to_nil(_), do: nil
end

defmodule HydraSrt.Ndi.Capabilities do
  @moduledoc """
  Stable NDI capability snapshot describing supported receive, send and discovery.

  Composes `HydraSrt.Ndi.FeaturePolicy` with the discovery helper capability from
  `HydraSrt.Ndi.Discovery.snapshot/0`. Also owns discovery REST presentation:
  opaque selection tokens, generation metadata, duplicate grouping, and refresh
  rate limiting. Never exposes absolute runtime paths.
  """

  alias HydraSrt.Ndi.Discovery
  alias HydraSrt.Ndi.FeaturePolicy

  @node_id "self"
  @capability_ttl_ms :timer.seconds(15)
  @token_ttl_ms :timer.seconds(15)
  @refresh_min_interval_ms :timer.seconds(2)
  @max_sources 256
  @discovery_mode "mdns"
  @supported_formats ~w(uyvy-bgra fastest best bgrx-bgra rgbx-rgba uyvy-rgba)

  @cache HydraSrt.Cache

  @type reason_code :: String.t()

  @type plugin_info :: %{
          available: boolean(),
          revision: String.t() | nil
        }

  @type runtime_info :: %{
          available: boolean(),
          major: integer() | nil,
          version: String.t() | nil
        }

  @type gated_formats :: %{
          available: boolean(),
          reason_codes: [reason_code()],
          formats: [String.t()]
        }

  @type gated_discovery :: %{
          available: boolean(),
          reason_codes: [reason_code()],
          mode: String.t()
        }

  @type gated_direct :: %{
          available: boolean(),
          reason_codes: [reason_code()]
        }

  @type t :: %{
          node_id: String.t(),
          feature_enabled: boolean(),
          plugin: plugin_info(),
          runtime: runtime_info(),
          receive: gated_formats(),
          send: gated_formats(),
          discovery: gated_discovery(),
          direct_address: gated_direct(),
          checked_at: String.t(),
          expires_at: String.t(),
          stale: boolean(),
          check_in_progress: boolean()
        }

  @type source_row :: %{
          selection_token: String.t(),
          name: String.t(),
          url_address: String.t() | nil,
          display_name: String.t(),
          last_seen_at: String.t() | nil,
          stale: boolean()
        }

  @type sources_meta :: %{
          generation: String.t(),
          scanned_at: String.t() | nil,
          expires_at: String.t(),
          refresh_in_progress: boolean(),
          truncated: boolean(),
          result_count: non_neg_integer(),
          duplicate_name_groups: [map()]
        }

  @type sources_result :: %{data: [source_row()], meta: sources_meta()}

  @type error_result :: {:error, reason_code(), String.t()}

  @type snapshot_fun :: (-> Discovery.snapshot())
  @type list_opts :: [
          principal: String.t(),
          q: String.t() | nil,
          refresh: boolean(),
          snapshot_fun: snapshot_fun(),
          refresh_fun: (-> :ok),
          now: DateTime.t()
        ]

  @type refresh_opts :: [
          principal: String.t(),
          refresh_fun: (-> :ok),
          now: DateTime.t()
        ]

  @doc """
  Returns the capability document.

  Options:
  - `:snapshot_fun` — injectable discovery snapshot (tests)
  - `:now` — fixed UTC clock (tests)
  """
  @spec get(keyword()) :: t()
  def get(opts \\ []) when is_list(opts) do
    snapshot_fun = Keyword.get(opts, :snapshot_fun, &Discovery.snapshot/0)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    compose(snapshot_fun.(), now)
  end

  @doc """
  Builds the capability document from a discovery snapshot.
  """
  @spec compose(Discovery.snapshot(), DateTime.t()) :: t()
  def compose(snapshot, now \\ DateTime.utc_now())
      when is_map(snapshot) and is_struct(now, DateTime) do
    checked_at = DateTime.truncate(now, :second)
    expires_at = DateTime.add(checked_at, div(@capability_ttl_ms, 1000), :second)
    feature_enabled = FeaturePolicy.enabled?()
    capability = snapshot[:capability] || Discovery.disabled_capability()
    helper_reason = normalize_reason(capability[:reason_code])
    helper_ok? = capability[:ok] == true
    check_in_progress? = helper_reason == "NDI_HELPER_PENDING"

    {plugin, runtime, platform_reasons} =
      plugin_runtime_from_helper(feature_enabled, helper_ok?, helper_reason)

    receive_gate =
      directional_gate(
        FeaturePolicy.receive?(),
        feature_enabled,
        helper_ok?,
        helper_reason,
        platform_reasons,
        runtime.available
      )

    send_gate =
      directional_gate(
        FeaturePolicy.send?(),
        feature_enabled,
        helper_ok?,
        helper_reason,
        platform_reasons,
        runtime.available
      )

    discovery_gate =
      discovery_gate(feature_enabled, helper_ok?, helper_reason, platform_reasons)

    direct_gate =
      direct_address_gate(
        FeaturePolicy.receive?(),
        feature_enabled,
        runtime.available,
        platform_reasons
      )

    %{
      node_id: @node_id,
      feature_enabled: feature_enabled,
      plugin: plugin,
      runtime: runtime,
      receive: receive_gate,
      send: send_gate,
      discovery: discovery_gate,
      direct_address: direct_gate,
      checked_at: DateTime.to_iso8601(checked_at),
      expires_at: DateTime.to_iso8601(expires_at),
      stale: snapshot[:stale] == true,
      check_in_progress: check_in_progress?
    }
  end

  @doc """
  Lists discovered NDI sources with opaque selection tokens.

  Returns `{:error, "NDI_DISABLED", _}` without touching discovery spawn state
  beyond reading the snapshot when the feature policy denies discovery.
  """
  @spec list_sources(list_opts()) :: {:ok, sources_result()} | error_result()
  def list_sources(opts) when is_list(opts) do
    principal = Keyword.fetch!(opts, :principal)

    case FeaturePolicy.deny_reason(:discovery) do
      reason when is_binary(reason) ->
        {:error, reason, "NDI discovery is disabled"}

      nil ->
        maybe_refresh = Keyword.get(opts, :refresh, false) == true
        refresh_fun = Keyword.get(opts, :refresh_fun, &Discovery.refresh/0)

        if maybe_refresh do
          _ = refresh_fun.()
        end

        snapshot_fun = Keyword.get(opts, :snapshot_fun, &Discovery.snapshot/0)
        now = Keyword.get(opts, :now, DateTime.utc_now())
        q = Keyword.get(opts, :q)
        snapshot = snapshot_fun.()
        present_sources(snapshot, principal, q, now)
    end
  end

  @doc """
  Requests a coalesced discovery refresh and returns a generation immediately.

  Rate-limited per principal: within the minimum interval, returns the current
  generation without calling refresh again. Always `202`-oriented when allowed.
  """
  @spec request_refresh(refresh_opts()) :: {:ok, %{generation: String.t()}} | error_result()
  def request_refresh(opts) when is_list(opts) do
    principal = Keyword.fetch!(opts, :principal)

    case FeaturePolicy.deny_reason(:discovery) do
      reason when is_binary(reason) ->
        {:error, reason, "NDI discovery is disabled"}

      nil ->
        now = Keyword.get(opts, :now, DateTime.utc_now())
        refresh_fun = Keyword.get(opts, :refresh_fun, &Discovery.refresh/0)

        generation =
          if refresh_allowed?(principal, now) do
            _ = refresh_fun.()
            mint_generation(now, principal)
          else
            current_or_mint_generation(now)
          end

        {:ok, %{generation: generation}}
    end
  end

  @doc """
  Resolves an opaque selection token for the given principal.

  Tokens are bound to principal, node, generation, name/address tuple, and expiry.
  """
  @spec resolve_selection_token(String.t(), String.t(), DateTime.t()) ::
          {:ok, map()} | error_result()
  def resolve_selection_token(token, principal, now \\ DateTime.utc_now())
      when is_binary(token) and is_binary(principal) and is_struct(now, DateTime) do
    case Cachex.get(@cache, token_cache_key(token)) do
      {:ok, %{principal: ^principal, node_id: @node_id, expires_at: expires_at} = payload} ->
        if DateTime.compare(expires_at, now) == :gt do
          {:ok, payload}
        else
          _ = Cachex.del(@cache, token_cache_key(token))
          {:error, "NDI_DISCOVERY_UNAVAILABLE", "Selection token expired"}
        end

      {:ok, %{principal: _other}} ->
        {:error, "NDI_DISCOVERY_UNAVAILABLE", "Selection token is not valid for this principal"}

      {:ok, nil} ->
        {:error, "NDI_DISCOVERY_UNAVAILABLE", "Selection token not found or expired"}

      {:ok, _} ->
        {:error, "NDI_DISCOVERY_UNAVAILABLE", "Selection token not found or expired"}

      {:error, _reason} ->
        {:error, "NDI_DISCOVERY_UNAVAILABLE", "Selection token cache unavailable"}
    end
  end

  @doc """
  Stable capability TTL used for `expires_at` (milliseconds).
  """
  @spec capability_ttl_ms() :: pos_integer()
  def capability_ttl_ms, do: @capability_ttl_ms

  @doc """
  Maximum sources returned by the discovery list API.
  """
  @spec max_sources() :: pos_integer()
  def max_sources, do: @max_sources

  @spec present_sources(Discovery.snapshot(), String.t(), String.t() | nil, DateTime.t()) ::
          {:ok, sources_result()}
  def present_sources(snapshot, principal, q, now)
      when is_map(snapshot) and is_binary(principal) and is_struct(now, DateTime) do
    generation = current_or_mint_generation(now)
    expires_at = DateTime.add(DateTime.truncate(now, :second), div(@token_ttl_ms, 1000), :second)
    scanned_at = DateTime.to_iso8601(DateTime.truncate(now, :second))
    devices = snapshot[:devices] || []
    stale? = snapshot[:stale] == true
    truncated? = snapshot[:truncated] == true
    refresh_in_progress? = (snapshot[:capability] || %{})[:reason_code] == "NDI_HELPER_PENDING"

    sorted =
      devices
      |> Enum.map(&device_to_source_fields/1)
      |> Enum.reject(&is_nil/1)
      |> filter_query(q)
      |> Enum.sort_by(fn row -> {row.name, row.url_address || ""} end)

    {rows, overflow?} =
      if length(sorted) > @max_sources do
        {Enum.take(sorted, @max_sources), true}
      else
        {sorted, false}
      end

    duplicate_name_groups = duplicate_groups(rows)

    data =
      Enum.map(rows, fn row ->
        token = mint_selection_token(principal, generation, row, expires_at)

        %{
          selection_token: token,
          name: row.name,
          url_address: row.url_address,
          display_name: row.display_name,
          last_seen_at: scanned_at,
          stale: stale?
        }
      end)

    {:ok,
     %{
       data: data,
       meta: %{
         generation: generation,
         scanned_at: scanned_at,
         expires_at: DateTime.to_iso8601(expires_at),
         refresh_in_progress: refresh_in_progress?,
         truncated: truncated? or overflow?,
         result_count: length(data),
         duplicate_name_groups: duplicate_name_groups
       }
     }}
  end

  @spec device_to_source_fields(Discovery.device()) ::
          %{name: String.t(), display_name: String.t(), url_address: String.t() | nil} | nil
  def device_to_source_fields(device) when is_map(device) do
    name = device["display_name"] || device[:display_name]

    if is_binary(name) and name != "" do
      props = device["properties"] || device[:properties] || ""
      url = extract_url_address(props)

      %{
        name: name,
        display_name: name,
        url_address: url
      }
    else
      nil
    end
  end

  def device_to_source_fields(_), do: nil

  @spec extract_url_address(String.t()) :: String.t() | nil
  def extract_url_address(properties) when is_binary(properties) do
    patterns = [
      ~r/url-address=\(string\)([^,;]+)/,
      ~r/url-address=\(string\)"([^"]+)"/,
      ~r/url-address=([^,;\s]+)/
    ]

    Enum.find_value(patterns, fn pattern ->
      case Regex.run(pattern, properties) do
        [_, value] ->
          trimmed = String.trim(value) |> String.trim("\"")
          if trimmed != "", do: trimmed, else: nil

        _ ->
          nil
      end
    end)
  end

  def extract_url_address(_), do: nil

  @spec filter_query([map()], String.t() | nil) :: [map()]
  def filter_query(rows, q) when is_list(rows) and (is_nil(q) or q == ""), do: rows

  def filter_query(rows, q) when is_list(rows) and is_binary(q) do
    needle = String.downcase(q)

    Enum.filter(rows, fn row ->
      String.contains?(String.downcase(row.name), needle) or
        (is_binary(row.url_address) and String.contains?(String.downcase(row.url_address), needle))
    end)
  end

  @spec duplicate_groups([map()]) :: [map()]
  def duplicate_groups(rows) when is_list(rows) do
    rows
    |> Enum.group_by(& &1.name)
    |> Enum.flat_map(fn {name, group} ->
      addresses =
        group
        |> Enum.map(& &1.url_address)
        |> Enum.uniq()

      if length(group) > 1 and length(addresses) > 1 do
        [
          %{
            name: name,
            count: length(group),
            reason_code: "NDI_SOURCE_NAME_AMBIGUOUS"
          }
        ]
      else
        []
      end
    end)
    |> Enum.sort_by(& &1.name)
  end

  @spec mint_selection_token(String.t(), String.t(), map(), DateTime.t()) :: String.t()
  def mint_selection_token(principal, generation, row, expires_at)
      when is_binary(principal) and is_binary(generation) and is_map(row) and
             is_struct(expires_at, DateTime) do
    token = Ecto.UUID.generate()

    payload = %{
      principal: principal,
      node_id: @node_id,
      generation: generation,
      name: row.name,
      url_address: row.url_address,
      expires_at: expires_at
    }

    ttl = max(DateTime.diff(expires_at, DateTime.utc_now(), :millisecond), 1)
    _ = Cachex.put(@cache, token_cache_key(token), payload, ttl: ttl)
    token
  end

  @spec current_or_mint_generation(DateTime.t()) :: String.t()
  def current_or_mint_generation(now) when is_struct(now, DateTime) do
    case Cachex.get(@cache, generation_cache_key()) do
      {:ok, generation} when is_binary(generation) and generation != "" ->
        generation

      _ ->
        generation = Ecto.UUID.generate()
        _ = Cachex.put(@cache, generation_cache_key(), generation, ttl: @token_ttl_ms)
        _ = Cachex.put(@cache, generation_minted_at_key(), now, ttl: @token_ttl_ms)
        generation
    end
  end

  @spec refresh_allowed?(String.t(), DateTime.t()) :: boolean()
  def refresh_allowed?(principal, now) when is_binary(principal) and is_struct(now, DateTime) do
    case Cachex.get(@cache, refresh_rate_key(principal)) do
      {:ok, %DateTime{} = last} ->
        DateTime.diff(now, last, :millisecond) >= @refresh_min_interval_ms

      _ ->
        true
    end
  end

  @spec mint_generation(DateTime.t(), String.t()) :: String.t()
  def mint_generation(now, principal)
      when is_struct(now, DateTime) and is_binary(principal) do
    generation = Ecto.UUID.generate()
    _ = Cachex.put(@cache, generation_cache_key(), generation, ttl: @token_ttl_ms)
    _ = Cachex.put(@cache, generation_minted_at_key(), now, ttl: @token_ttl_ms)

    _ =
      Cachex.put(@cache, refresh_rate_key(principal), now, ttl: @refresh_min_interval_ms * 2)

    generation
  end

  @spec remember_refresh(String.t(), DateTime.t()) :: :ok
  def remember_refresh(principal, now) when is_binary(principal) and is_struct(now, DateTime) do
    _ = mint_generation(now, principal)
    :ok
  end

  @spec token_cache_key(String.t()) :: {:ndi_selection_token, String.t()}
  def token_cache_key(token) when is_binary(token), do: {:ndi_selection_token, token}

  @spec generation_cache_key() :: {:ndi_discovery_generation, String.t()}
  def generation_cache_key, do: {:ndi_discovery_generation, @node_id}

  @spec generation_minted_at_key() :: {:ndi_discovery_generation_at, String.t()}
  def generation_minted_at_key, do: {:ndi_discovery_generation_at, @node_id}

  @spec refresh_rate_key(String.t()) :: {:ndi_discovery_refresh, String.t()}
  def refresh_rate_key(principal) when is_binary(principal),
    do: {:ndi_discovery_refresh, principal}

  @spec plugin_runtime_from_helper(boolean(), boolean(), reason_code() | nil) ::
          {plugin_info(), runtime_info(), [reason_code()]}
  def plugin_runtime_from_helper(feature_enabled, helper_ok?, helper_reason) do
    cond do
      not feature_enabled ->
        {
          %{available: false, revision: nil},
          %{available: false, major: nil, version: nil},
          ["NDI_DISABLED"]
        }

      helper_reason == "NDI_PLUGIN_MISSING" ->
        {
          %{available: false, revision: nil},
          %{available: false, major: nil, version: nil},
          ["NDI_PLUGIN_MISSING"]
        }

      helper_reason == "NDI_RUNTIME_MISSING" ->
        {
          %{available: true, revision: nil},
          %{available: false, major: nil, version: nil},
          ["NDI_RUNTIME_MISSING"]
        }

      helper_reason == "NDI_RUNTIME_INCOMPATIBLE" ->
        {
          %{available: true, revision: nil},
          %{available: false, major: nil, version: nil},
          ["NDI_RUNTIME_INCOMPATIBLE"]
        }

      helper_reason in ["NDI_PLATFORM_UNSUPPORTED", "NDI_CPU_UNSUPPORTED"] ->
        {
          %{available: false, revision: nil},
          %{available: false, major: nil, version: nil},
          [helper_reason]
        }

      helper_reason == "NDI_AVAHI_UNAVAILABLE" ->
        {
          %{available: true, revision: nil},
          %{available: true, major: nil, version: nil},
          ["NDI_AVAHI_UNAVAILABLE"]
        }

      helper_reason in ["NDI_HELPER_UNHEALTHY", "NDI_HELPER_PENDING", "NDI_DISCOVERY_UNAVAILABLE"] ->
        {
          %{available: false, revision: nil},
          %{available: false, major: nil, version: nil},
          [helper_reason || "NDI_HELPER_UNHEALTHY"]
        }

      helper_ok? ->
        {
          %{available: true, revision: nil},
          %{available: true, major: nil, version: nil},
          []
        }

      is_binary(helper_reason) ->
        {
          %{available: false, revision: nil},
          %{available: false, major: nil, version: nil},
          [helper_reason]
        }

      true ->
        {
          %{available: false, revision: nil},
          %{available: false, major: nil, version: nil},
          ["NDI_DISCOVERY_UNAVAILABLE"]
        }
    end
  end

  @spec directional_gate(
          boolean(),
          boolean(),
          boolean(),
          reason_code() | nil,
          [reason_code()],
          boolean()
        ) :: gated_formats()
  def directional_gate(
        direction_allowed?,
        feature_enabled,
        helper_ok?,
        helper_reason,
        platform_reasons,
        runtime_available?
      ) do
    # Avahi only blocks discovery mode; receive/send stay up when the runtime works.
    media_reasons =
      Enum.reject(platform_reasons, &(&1 in ["NDI_AVAHI_UNAVAILABLE", "NDI_HELPER_PENDING"]))

    cond do
      not feature_enabled or not direction_allowed? ->
        %{available: false, reason_codes: ["NDI_DISABLED"], formats: []}

      runtime_available? and (helper_ok? or helper_reason == "NDI_AVAHI_UNAVAILABLE") ->
        %{available: true, reason_codes: [], formats: @supported_formats}

      media_reasons != [] ->
        %{available: false, reason_codes: media_reasons, formats: []}

      is_binary(helper_reason) and helper_reason != "NDI_AVAHI_UNAVAILABLE" ->
        %{available: false, reason_codes: [helper_reason], formats: []}

      true ->
        %{available: false, reason_codes: ["NDI_DISCOVERY_UNAVAILABLE"], formats: []}
    end
  end

  @spec discovery_gate(boolean(), boolean(), reason_code() | nil, [reason_code()]) ::
          gated_discovery()
  def discovery_gate(feature_enabled, helper_ok?, helper_reason, platform_reasons) do
    cond do
      not feature_enabled ->
        %{available: false, reason_codes: ["NDI_DISABLED"], mode: @discovery_mode}

      helper_reason == "NDI_AVAHI_UNAVAILABLE" ->
        %{available: false, reason_codes: ["NDI_AVAHI_UNAVAILABLE"], mode: @discovery_mode}

      helper_ok? ->
        %{available: true, reason_codes: [], mode: @discovery_mode}

      platform_reasons != [] ->
        %{available: false, reason_codes: platform_reasons, mode: @discovery_mode}

      is_binary(helper_reason) ->
        %{available: false, reason_codes: [helper_reason], mode: @discovery_mode}

      true ->
        %{available: false, reason_codes: ["NDI_DISCOVERY_UNAVAILABLE"], mode: @discovery_mode}
    end
  end

  @spec direct_address_gate(boolean(), boolean(), boolean(), [reason_code()]) :: gated_direct()
  def direct_address_gate(receive_allowed?, feature_enabled, runtime_available?, platform_reasons) do
    cond do
      not feature_enabled or not receive_allowed? ->
        %{available: false, reason_codes: ["NDI_DISABLED"]}

      runtime_available? ->
        # Direct address does not require mDNS/Avahi.
        reasons =
          Enum.reject(platform_reasons, &(&1 in ["NDI_AVAHI_UNAVAILABLE", "NDI_HELPER_PENDING"]))

        if reasons == [] do
          %{available: true, reason_codes: []}
        else
          %{available: false, reason_codes: reasons}
        end

      platform_reasons != [] ->
        %{available: false, reason_codes: platform_reasons}

      true ->
        %{available: false, reason_codes: ["NDI_RUNTIME_MISSING"]}
    end
  end

  @spec normalize_reason(term()) :: reason_code() | nil
  def normalize_reason(reason) when is_binary(reason) and reason != "", do: reason
  def normalize_reason(_), do: nil
end

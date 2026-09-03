defmodule HydraSrt.CallerLabels do
  @moduledoc false

  import Bitwise
  import Ecto.Query, only: [from: 2]
  require Logger

  alias HydraSrt.Api.CallerLabel
  alias HydraSrt.Repo

  @cache_key :hydra_srt_caller_labels
  @cache_ttl_ms :timer.minutes(30)

  @type address_tuple :: {tuple(), non_neg_integer(), boolean()}

  @spec list() :: [CallerLabel.t()]
  def list do
    Repo.all(from label in CallerLabel, order_by: [asc: label.address])
  end

  @spec get(String.t()) :: {:ok, CallerLabel.t()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    case Repo.get(CallerLabel, id) do
      %CallerLabel{} = label -> {:ok, label}
      nil -> {:error, :not_found}
    end
  end

  @spec create(map()) :: {:ok, CallerLabel.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) when is_map(attrs) do
    %CallerLabel{}
    |> CallerLabel.changeset(attrs)
    |> Repo.insert()
    |> invalidate_after_write()
  end

  @spec update(String.t(), map()) :: {:ok, CallerLabel.t()} | {:error, term()}
  def update(id, attrs) when is_binary(id) and is_map(attrs) do
    case Repo.get(CallerLabel, id) do
      %CallerLabel{} = label -> update_record(label, attrs)
      nil -> {:error, :not_found}
    end
  end

  @spec update_record(CallerLabel.t(), map()) :: {:ok, CallerLabel.t()} | {:error, term()}
  def update_record(%CallerLabel{} = label, attrs) when is_map(attrs) do
    label
    |> CallerLabel.changeset(attrs)
    |> Repo.update()
    |> invalidate_after_write()
  end

  @spec delete(String.t()) :: {:ok, CallerLabel.t()} | {:error, :not_found}
  def delete(id) when is_binary(id) do
    case Repo.get(CallerLabel, id) do
      %CallerLabel{} = label -> Repo.delete(label) |> invalidate_after_write()
      nil -> {:error, :not_found}
    end
  end

  @spec label_for_ip(String.t()) :: String.t() | nil
  def label_for_ip(ip) when is_binary(ip) do
    case parse_ip(ip) do
      {:ok, ip_tuple} ->
        cached_labels()
        |> Enum.flat_map(&matching_label(&1, ip_tuple))
        |> Enum.sort_by(
          fn {_label, exact?, prefix} -> {if(exact?, do: 1, else: 0), prefix} end,
          :desc
        )
        |> case do
          [{label, _exact?, _prefix} | _] -> label
          [] -> nil
        end

      :error ->
        nil
    end
  end

  @spec valid_address?(term()) :: boolean()
  def valid_address?(address) when is_binary(address), do: parse_network(address) != :error
  def valid_address?(_address), do: false

  @spec ip_in_network?(String.t(), String.t()) :: boolean()
  def ip_in_network?(ip, network) when is_binary(ip) and is_binary(network) do
    with {:ok, ip_tuple} <- parse_ip(ip),
         {:ok, {network_tuple, prefix, _exact?}} <- parse_network(network) do
      contains?(ip_tuple, network_tuple, prefix)
    else
      _ -> false
    end
  end

  @spec parse_network(String.t()) :: {:ok, address_tuple()} | :error
  def parse_network(address) when is_binary(address) do
    case String.split(String.trim(address), "/", parts: 2) do
      [ip] ->
        with {:ok, tuple} <- parse_ip(ip) do
          {:ok, {tuple, address_bits(tuple), true}}
        else
          _ -> :error
        end

      [ip, prefix_text] ->
        with {:ok, tuple} <- parse_ip(ip),
             {prefix, ""} <- Integer.parse(prefix_text),
             true <- prefix >= 0 and prefix <= address_bits(tuple) do
          {:ok, {tuple, prefix, false}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  @spec parse_ip(String.t()) :: {:ok, tuple()} | :error
  def parse_ip(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(String.trim(ip))) do
      {:ok, tuple} -> {:ok, tuple}
      {:error, _reason} -> :error
    end
  end

  @spec cached_labels() :: [CallerLabel.t()]
  def cached_labels do
    case Process.whereis(HydraSrt.Cache) do
      pid when is_pid(pid) ->
        case Cachex.get(HydraSrt.Cache, @cache_key) do
          {:ok, labels} when is_list(labels) -> labels
          _ -> cache_labels()
        end

      _ ->
        list()
    end
  end

  @spec cache_labels() :: [CallerLabel.t()]
  def cache_labels do
    labels = list()

    if Process.whereis(HydraSrt.Cache) do
      _ = Cachex.put(HydraSrt.Cache, @cache_key, labels, ttl: @cache_ttl_ms)
    end

    labels
  end

  @spec invalidate() :: :ok
  def invalidate do
    if Process.whereis(HydraSrt.Cache) do
      _ = Cachex.del(HydraSrt.Cache, @cache_key)
    end

    :ok
  end

  @spec invalidate_after_write({:ok, term()} | {:error, term()}) ::
          {:ok, term()} | {:error, term()}
  def invalidate_after_write(result) do
    invalidate()
    result
  end

  @spec matching_label(CallerLabel.t(), tuple()) :: [{String.t(), boolean(), non_neg_integer()}]
  def matching_label(%CallerLabel{address: address, label: label}, ip_tuple)
      when is_binary(address) and is_binary(label) do
    case parse_network(address) do
      {:ok, {network_tuple, prefix, exact?}} ->
        if tuple_family?(network_tuple) == tuple_family?(ip_tuple) and
             contains?(ip_tuple, network_tuple, prefix) do
          [{label, exact?, prefix}]
        else
          []
        end

      :error ->
        Logger.warning("Skipping invalid stored caller label address=#{inspect(address)}")
        []
    end
  end

  @spec contains?(tuple(), tuple(), non_neg_integer()) :: boolean()
  def contains?(ip_tuple, network_tuple, prefix) do
    bits = address_bits(ip_tuple)

    if address_bits(network_tuple) == bits do
      shift = bits - prefix
      mask = if prefix == 0, do: 0, else: ((1 <<< prefix) - 1) <<< shift
      (tuple_to_integer(ip_tuple) &&& mask) == (tuple_to_integer(network_tuple) &&& mask)
    else
      false
    end
  end

  @spec tuple_to_integer(tuple()) :: non_neg_integer()
  def tuple_to_integer({a, b, c, d}), do: Enum.reduce([a, b, c, d], 0, &(&2 <<< 8 ||| &1))

  def tuple_to_integer({a, b, c, d, e, f, g, h}),
    do: Enum.reduce([a, b, c, d, e, f, g, h], 0, &(&2 <<< 16 ||| &1))

  @spec address_bits(tuple()) :: 32 | 128
  def address_bits({_, _, _, _}), do: 32
  def address_bits({_, _, _, _, _, _, _, _}), do: 128

  @spec tuple_family?(tuple()) :: :ipv4 | :ipv6
  def tuple_family?({_, _, _, _}), do: :ipv4
  def tuple_family?({_, _, _, _, _, _, _, _}), do: :ipv6
end

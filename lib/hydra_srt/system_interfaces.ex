defmodule HydraSrt.SystemInterfaces do
  @moduledoc false

  @spec discover() :: {:ok, list(map())} | {:error, term()}
  def discover do
    case System.cmd("ifconfig", []) do
      {output, 0} ->
        {:ok, parse_ifconfig(output)}

      {_output, code} ->
        {:error, {:ifconfig_failed, code}}
    end
  rescue
    error -> {:error, error}
  end

  @spec discover_raw() :: {:ok, binary()} | {:error, term()}
  def discover_raw do
    case System.cmd("ifconfig", []) do
      {output, 0} ->
        {:ok, output}

      {_output, code} ->
        {:error, {:ifconfig_failed, code}}
    end
  rescue
    error -> {:error, error}
  end

  @spec parse_ifconfig(binary()) :: list(map())
  def parse_ifconfig(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.reduce({[], nil}, &reduce_line/2)
    |> finalize_parse()
  end

  @doc false
  def reduce_line(line, {acc, current}) when is_binary(line) do
    case Regex.run(~r/^([^\s:]+):\s/, line) do
      [_, sys_name] ->
        next_acc =
          case current do
            nil -> acc
            _ -> [current | acc]
          end

        {next_acc,
         %{
           "sys_name" => sys_name,
           "ip" => nil,
           "multicast_supported" => line_supports_multicast?(line),
           "raw_lines" => [line]
         }}

      _ ->
        {acc, maybe_apply_line(current, line)}
    end
  end

  @doc false
  def finalize_parse({acc, nil}) do
    acc
    |> Enum.reverse()
    |> Enum.map(&finalize_interface/1)
  end

  def finalize_parse({acc, current}) do
    [current | acc]
    |> Enum.reverse()
    |> Enum.map(&finalize_interface/1)
  end

  @doc false
  def maybe_apply_line(nil, _line), do: nil

  def maybe_apply_line(current, line) when is_map(current) and is_binary(line) do
    current =
      if line == "" do
        current
      else
        current
        |> Map.update("raw_lines", [line], fn lines -> lines ++ [line] end)
      end

    current
    |> maybe_apply_ipv4(line)
    |> maybe_apply_ipv6(line)
  end

  @doc false
  def finalize_interface(interface) when is_map(interface) do
    interface
    |> Map.update("ip", "-", fn
      nil -> "-"
      "" -> "-"
      value -> value
    end)
    |> Map.put("raw_description", Enum.join(Map.get(interface, "raw_lines", []), "\n"))
    |> Map.delete("raw_lines")
  end

  @doc false
  def maybe_apply_ipv4(current, line) when is_map(current) and is_binary(line) do
    case Regex.run(~r/^\s+inet\s+(\d+\.\d+\.\d+\.\d+)(?:\s+netmask\s+(\S+))?/, line) do
      [_, ip, netmask] ->
        Map.put(current, "ip", with_cidr(ip, netmask))

      [_, ip] ->
        Map.put(current, "ip", ip)

      _ ->
        current
    end
  end

  @doc false
  def maybe_apply_ipv6(current, line) when is_map(current) and is_binary(line) do
    if current["ip"] do
      current
    else
      case Regex.run(
             ~r/^\s+inet6\s+([0-9a-fA-F:]+(?:%[a-zA-Z0-9]+)?)(?:\s+prefixlen\s+(\d+))?/,
             line
           ) do
        [_, ip6, prefix] when is_binary(prefix) ->
          Map.put(current, "ip", "#{ip6}/#{prefix}")

        [_, ip6] ->
          Map.put(current, "ip", ip6)

        _ ->
          current
      end
    end
  end

  @doc false
  def line_supports_multicast?(line) when is_binary(line) do
    String.contains?(line, "MULTICAST")
  end

  @doc false
  def with_cidr(ip, netmask) when is_binary(ip) and is_binary(netmask) do
    case netmask_to_prefix(netmask) do
      nil -> ip
      prefix -> "#{ip}/#{prefix}"
    end
  end

  @doc false
  def netmask_to_prefix("0x" <> rest), do: hex_netmask_to_prefix(rest)
  def netmask_to_prefix(netmask) when is_binary(netmask), do: dotted_netmask_to_prefix(netmask)

  @doc false
  def hex_netmask_to_prefix(rest) when is_binary(rest) do
    case Integer.parse(rest, 16) do
      {value, ""} when value >= 0 -> popcount(value)
      _ -> nil
    end
  end

  @doc false
  def dotted_netmask_to_prefix(netmask) when is_binary(netmask) do
    parts =
      netmask
      |> String.split(".")
      |> Enum.map(&Integer.parse/1)

    if length(parts) == 4 and
         Enum.all?(parts, &match?({value, ""} when value >= 0 and value <= 255, &1)) do
      parts
      |> Enum.map(fn {value, ""} -> value end)
      |> Enum.map(&popcount/1)
      |> Enum.sum()
    else
      nil
    end
  end

  @doc false
  def popcount(value) when is_integer(value) and value >= 0 do
    value
    |> Integer.to_string(2)
    |> String.graphemes()
    |> Enum.count(&(&1 == "1"))
  end
end

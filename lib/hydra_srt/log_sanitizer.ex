defmodule HydraSrt.LogSanitizer do
  @moduledoc """
  Redacts operator secrets and peer addresses before they reach the log.
  """

  @secret_mask "[REDACTED]"
  @ip_mask "[REDACTED_IP]"

  # `"passphrase":"..."` in the JSON payload, honouring backslash escapes.
  @json_passphrase ~r/("passphrase"\s*:\s*)"(?:[^"\\]|\\.)*"/
  # `passphrase=...` inside an `srt://` URI, which ends at `&`, `"` or whitespace.
  @query_passphrase ~r/(passphrase=)[^&"\s]+/
  @ipv4 ~r/\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/

  @doc """
  Masks passphrases and public IPv4 addresses in a route command payload.
  """
  @spec sanitize_payload(term()) :: term()
  def sanitize_payload(value) when is_binary(value) do
    value
    |> mask_passphrase()
    |> mask_public_ips()
  end

  def sanitize_payload(value), do: value

  @doc """
  Masks SRT passphrases, both as a JSON field and as a URI query parameter.
  """
  @spec mask_passphrase(term()) :: term()
  def mask_passphrase(value) when is_binary(value) do
    value
    |> then(&Regex.replace(@json_passphrase, &1, "\\1\"#{@secret_mask}\""))
    |> then(&Regex.replace(@query_passphrase, &1, "\\1#{@secret_mask}"))
  end

  def mask_passphrase(value), do: value

  @doc """
  Masks every publicly routable IPv4 address, leaving local addresses readable.
  """
  @spec mask_public_ips(term()) :: term()
  def mask_public_ips(value) when is_binary(value) do
    Regex.replace(@ipv4, value, fn match ->
      if public_ip?(match), do: @ip_mask, else: match
    end)
  end

  def mask_public_ips(value), do: value

  @doc false
  @spec public_ip?(String.t()) :: boolean()
  def public_ip?(address) when is_binary(address) do
    case :inet.parse_ipv4strict_address(String.to_charlist(address)) do
      {:ok, octets} -> not local_ip?(octets)
      _ -> false
    end
  end

  defp local_ip?({0, _, _, _}), do: true
  defp local_ip?({10, _, _, _}), do: true
  defp local_ip?({127, _, _, _}), do: true
  defp local_ip?({100, b, _, _}) when b >= 64 and b <= 127, do: true
  defp local_ip?({169, 254, _, _}), do: true
  defp local_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp local_ip?({192, 168, _, _}), do: true
  defp local_ip?({255, 255, 255, 255}), do: true
  # Multicast and reserved: stream groups, not peer identities.
  defp local_ip?({a, _, _, _}) when a >= 224, do: true
  # Documentation ranges used by tests and docs.
  defp local_ip?({192, 0, 2, _}), do: true
  defp local_ip?({198, 51, 100, _}), do: true
  defp local_ip?({203, 0, 113, _}), do: true
  defp local_ip?(_), do: false
end

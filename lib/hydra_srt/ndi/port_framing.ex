defmodule HydraSrt.Ndi.PortFraming do
  @moduledoc false

  @discovery_max_line_bytes 524_288
  @probe_max_line_bytes 65_536

  @doc """
  Splits Port chunks into complete JSONL lines.

  Returns `{:ok, lines, rest, oversized?}` — an oversize line is skipped and
  parsing continues on the remainder of the chunk (does not discard later lines).
  """
  @spec append_port_data(binary(), binary(), pos_integer()) ::
          {:ok, [binary()], binary(), boolean()}
  def append_port_data(buffer, chunk, max_line_bytes)
      when is_binary(buffer) and is_binary(chunk) and is_integer(max_line_bytes) and
             max_line_bytes > 0 do
    combined = buffer <> chunk
    split_complete_lines(combined, [], false, max_line_bytes)
  end

  @spec split_complete_lines(binary(), [binary()], boolean(), pos_integer()) ::
          {:ok, [binary()], binary(), boolean()}
  def split_complete_lines(buffer, acc, oversized, max_line_bytes)
      when is_binary(buffer) and is_list(acc) and is_boolean(oversized) and
             is_integer(max_line_bytes) and max_line_bytes > 0 do
    case :binary.split(buffer, "\n") do
      [line, rest] ->
        if byte_size(line) > max_line_bytes do
          split_complete_lines(rest, acc, true, max_line_bytes)
        else
          split_complete_lines(rest, [line | acc], oversized, max_line_bytes)
        end

      [rest] ->
        if byte_size(rest) > max_line_bytes do
          {:ok, Enum.reverse(acc), "", true}
        else
          {:ok, Enum.reverse(acc), rest, oversized}
        end
    end
  end

  @spec append_discovery_port_data(binary(), binary()) ::
          {:ok, [binary()], binary(), boolean()}
  def append_discovery_port_data(buffer, chunk) when is_binary(buffer) and is_binary(chunk) do
    append_port_data(buffer, chunk, @discovery_max_line_bytes)
  end

  @spec split_discovery_complete_lines(binary(), [binary()], boolean()) ::
          {:ok, [binary()], binary(), boolean()}
  def split_discovery_complete_lines(buffer, acc, oversized) do
    split_complete_lines(buffer, acc, oversized, @discovery_max_line_bytes)
  end

  @spec append_probe_port_data(binary(), binary()) ::
          {:ok, [binary()], binary(), boolean()}
  def append_probe_port_data(buffer, chunk) when is_binary(buffer) and is_binary(chunk) do
    append_port_data(buffer, chunk, @probe_max_line_bytes)
  end

  @spec split_probe_complete_lines(binary(), [binary()], boolean()) ::
          {:ok, [binary()], binary(), boolean()}
  def split_probe_complete_lines(buffer, acc, oversized) do
    split_complete_lines(buffer, acc, oversized, @probe_max_line_bytes)
  end

  @spec max_line_bytes() :: pos_integer()
  def max_line_bytes, do: @discovery_max_line_bytes
end

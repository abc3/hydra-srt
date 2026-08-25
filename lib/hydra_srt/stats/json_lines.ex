defmodule HydraSrt.Stats.JsonLines do
  @moduledoc false

  @spec parse_json_lines(binary()) :: [map()]
  def parse_json_lines(body) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, decoded} when is_map(decoded) -> [decoded]
        _ -> []
      end
    end)
  end
end

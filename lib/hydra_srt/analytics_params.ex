defmodule HydraSrt.AnalyticsParams do
  @moduledoc false

  @spec normalize(map()) :: map()
  def normalize(params) when is_map(params) do
    params
    |> Enum.reduce(%{}, fn
      {key, value}, acc when is_binary(key) and not is_nil(value) and value != "" ->
        Map.put(acc, key, to_string(value))

      _, acc ->
        acc
    end)
  end
end

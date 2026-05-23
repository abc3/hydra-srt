defmodule HydraSrt.Pagination do
  @moduledoc false

  @default_page 1
  @default_limit 50
  @max_limit 500

  @spec default_page() :: pos_integer()
  def default_page, do: @default_page

  @spec default_limit() :: pos_integer()
  def default_limit, do: @default_limit

  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @spec parse_page(map(), String.t()) :: pos_integer()
  def parse_page(params, key \\ "page") when is_map(params) do
    parse_positive_int(Map.get(params, key), @default_page)
  end

  @spec parse_limit(map(), String.t()) :: pos_integer()
  def parse_limit(params, key \\ "limit") when is_map(params) do
    parse_positive_int(Map.get(params, key), @default_limit)
  end

  @spec parse_sort_by(map(), [String.t()], String.t()) :: String.t()
  def parse_sort_by(params, allowed \\ ["created_at", "updated_at"], default \\ "created_at")
      when is_map(params) and is_list(allowed) do
    sort_by = Map.get(params, "sort_by")

    if sort_by in allowed, do: sort_by, else: default
  end

  @spec parse_positive_int(term(), pos_integer()) :: pos_integer()
  def parse_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  def parse_positive_int(value, _default) when is_integer(value) and value > 0, do: value
  def parse_positive_int(_value, default), do: default
end

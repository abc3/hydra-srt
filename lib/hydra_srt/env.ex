defmodule HydraSrt.Env do
  @moduledoc false

  @spec get_integer(binary(), integer() | nil) :: integer() | nil
  def get_integer(env, default \\ nil)

  def get_integer(env, default) when is_integer(default) or is_nil(default) do
    value = System.get_env(env)

    if value do
      case Integer.parse(value) do
        {int, ""} -> int
        _ -> raise ArgumentError, "env #{env} expected an integer, got #{inspect(value)}"
      end
    else
      default
    end
  end

  def get_integer(env, default) do
    raise ArgumentError,
          "expected integer or nil as default for env #{env}, got #{inspect(default)}"
  end

  @spec get_boolean(binary(), boolean()) :: boolean()
  def get_boolean(env, default) when is_boolean(default) do
    value = System.get_env(env)

    if value do
      value =
        value
        |> String.trim()
        |> String.downcase()

      cond do
        value in ["true", "1", "yes"] -> true
        value in ["false", "0", "no"] -> false
        true -> raise ArgumentError, "env #{env} expected boolean/0/1, got #{inspect(value)}"
      end
    else
      default
    end
  end

  def get_boolean(env, default) do
    raise ArgumentError, "expected boolean as default for env #{env}, got #{inspect(default)}"
  end

  @spec get_binary(binary(), binary() | nil) :: binary() | nil
  def get_binary(env, default \\ nil)

  def get_binary(env, default) when is_binary(default) or is_nil(default) do
    System.get_env(env, default)
  end

  def get_binary(env, default) do
    raise ArgumentError,
          "expected binary or nil as default for env #{env}, got #{inspect(default)}"
  end

  @spec get_list(binary(), [binary()]) :: [binary()]
  def get_list(env, default) when is_list(default) do
    value = System.get_env(env)

    if value do
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    else
      default
    end
  end

  def get_list(env, default) do
    raise ArgumentError, "expected list as default for env #{env}, got #{inspect(default)}"
  end
end

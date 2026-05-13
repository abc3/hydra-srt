defmodule HydraSrt.EnvTest do
  use ExUnit.Case, async: true

  alias HydraSrt.Env

  @env_key "PHX_CHECK_ORIGIN_TEST"

  setup do
    original = System.get_env(@env_key)

    on_exit(fn ->
      if is_nil(original) do
        System.delete_env(@env_key)
      else
        System.put_env(@env_key, original)
      end
    end)

    :ok
  end

  test "returns true when env var is unset" do
    System.delete_env(@env_key)
    assert Env.get_check_origin(@env_key) == true
  end

  test "returns true when env var is empty" do
    System.put_env(@env_key, "")
    assert Env.get_check_origin(@env_key) == true
  end

  test "returns origins list when env var is CSV" do
    System.put_env(@env_key, "http://198.51.100.10:40321,http://203.0.113.20:4000")

    assert Env.get_check_origin(@env_key) == [
             "http://198.51.100.10:40321",
             "http://203.0.113.20:4000"
           ]
  end
end

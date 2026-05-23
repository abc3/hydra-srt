defmodule HydraSrt.HelpersTest do
  use ExUnit.Case, async: true

  alias HydraSrt.Helpers

  describe "get_by_string_key/3" do
    test "returns string-key value when present, including nil and false" do
      map = %{"enabled" => false, "note" => nil, "bot_token" => "token"}

      assert Helpers.get_by_string_key(map, "enabled") == false
      assert Helpers.get_by_string_key(map, "note") == nil
      assert Helpers.get_by_string_key(map, "bot_token") == "token"
    end

    test "falls back to existing atom key when string key is absent" do
      map = %{bot_token: "secret"}

      assert Helpers.get_by_string_key(map, "bot_token") == "secret"
    end

    test "returns default when neither key form is present" do
      assert Helpers.get_by_string_key(%{}, "bot_token", :missing) == :missing
    end
  end

  describe "get_by_string_key_or/3" do
    test "falls back to atom key when string-key value is nil or false" do
      assert Helpers.get_by_string_key_or(%{"bot_token" => nil, bot_token: "secret"}, "bot_token") ==
               "secret"

      assert Helpers.get_by_string_key_or(
               %{"bot_token" => false, bot_token: "secret"},
               "bot_token"
             ) ==
               "secret"
    end

    test "does not fall back to atom key when string-key value is empty string" do
      map = %{"bot_token" => "", bot_token: "secret"}

      assert Helpers.get_by_string_key_or(map, "bot_token") == ""
    end

    test "prefers truthy string-key value over atom key" do
      map = %{"bot_token" => "primary", bot_token: "secondary"}

      assert Helpers.get_by_string_key_or(map, "bot_token") == "primary"
    end

    test "uses atom key when string key is absent" do
      map = %{chat_id: "42"}

      assert Helpers.get_by_string_key_or(map, "chat_id") == "42"
    end
  end

  describe "has_string_key?/2" do
    test "detects string or existing atom keys without creating atoms" do
      map = %{chat_id: "1"}

      assert Helpers.has_string_key?(map, "chat_id")
      refute Helpers.has_string_key?(map, "missing_key_#{System.unique_integer()}")
    end
  end
end

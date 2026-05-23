defmodule HydraSrt.Mcp.InputSchemaTest do
  use ExUnit.Case, async: true

  alias HydraSrt.Mcp.InputSchema

  test "converts required and optional string fields" do
    schema = %{
      "type" => "object",
      "required" => ["name"],
      "properties" => %{
        "name" => %{"type" => "string"},
        "note" => %{"type" => "string"}
      }
    }

    assert InputSchema.to_hermes(schema) == %{
             "name" => {:required, :any},
             "note" => :any
           }
  end

  test "converts enum string fields" do
    schema = %{
      "type" => "object",
      "required" => ["mode"],
      "properties" => %{
        "mode" => %{"type" => "string", "enum" => ["caller", "listener"]}
      }
    }

    assert InputSchema.to_hermes(schema) == %{
             "mode" => {:required, {:enum, ["caller", "listener"], [type: :string]}}
           }
  end

  test "converts integer and string list fields" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "port" => %{"type" => "integer"},
        "tags" => %{"type" => "array", "items" => %{"type" => "string"}}
      }
    }

    assert InputSchema.to_hermes(schema) == %{
             "port" => :integer,
             "tags" => {:list, :string}
           }
  end

  test "converts nested object fields" do
    schema = %{
      "type" => "object",
      "required" => ["route"],
      "properties" => %{
        "route" => %{
          "type" => "object",
          "required" => ["name"],
          "properties" => %{
            "name" => %{"type" => "string"}
          }
        }
      }
    }

    assert InputSchema.to_hermes(schema) == %{
             "route" => {:required, {:object, %{"name" => {:required, :any}}}}
           }
  end

  test "empty nested object becomes any" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "payload" => %{"type" => "object"}
      }
    }

    assert InputSchema.to_hermes(schema) == %{"payload" => :any}
  end

  test "non-object schema returns empty map" do
    assert InputSchema.to_hermes(%{"type" => "string"}) == %{}
  end
end

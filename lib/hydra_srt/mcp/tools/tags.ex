defmodule HydraSrt.Mcp.Tools.Tags do
  @moduledoc false

  alias HydraSrt.Mcp.Helpers
  alias HydraSrt.Mcp.Tools.Routes, as: Schema
  alias HydraSrt.Tags

  @spec definitions() :: [map()]
  def definitions do
    [
      %{
        name: "list_tags",
        description: "List route tags.",
        input_schema: Schema.object_schema(%{})
      },
      %{
        name: "create_tag",
        description: "Create a route tag.",
        input_schema:
          Schema.object_schema(%{"tag" => Schema.object_prop("Tag attributes (name)")}, ["tag"])
      },
      %{
        name: "update_tag",
        description: "Update a route tag.",
        input_schema:
          Schema.object_schema(
            %{
              "tag_id" => Schema.string_prop("Tag ID"),
              "tag" => Schema.object_prop("Tag attributes (name)")
            },
            ["tag_id", "tag"]
          )
      },
      %{
        name: "delete_tag",
        description: "Delete a route tag.",
        input_schema:
          Schema.object_schema(%{"tag_id" => Schema.string_prop("Tag ID")}, ["tag_id"])
      }
    ]
  end

  @spec handles?(String.t()) :: boolean()
  def handles?(name), do: name in Enum.map(definitions(), & &1.name)

  @spec call(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call("list_tags", _args) do
    {:ok, Helpers.ok(Tags.list())}
  end

  def call("create_tag", args) do
    with {:ok, tag} <- Schema.map_param(args, "tag"),
         result <- Tags.create(tag) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call("update_tag", args) do
    with {:ok, tag_id} <- Schema.param(args, "tag_id"),
         {:ok, tag} <- Schema.map_param(args, "tag"),
         result <- Tags.update(tag_id, tag) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call("delete_tag", args) do
    with {:ok, tag_id} <- Schema.param(args, "tag_id") do
      case Tags.delete(tag_id) do
        {:ok, _tag} -> {:ok, Helpers.ok(%{"deleted" => true, "tag_id" => tag_id})}
        error -> {:ok, Helpers.from_result(error)}
      end
    end
  end

  def call(_name, _args), do: :unknown
end

defmodule HydraSrt.Mcp.InputSchema do
  @moduledoc false

  @spec to_hermes(map()) :: map()
  def to_hermes(%{"type" => "object", "properties" => properties} = schema)
      when is_map(properties) do
    required = Map.get(schema, "required", [])

    Map.new(properties, fn {key, property} ->
      {key, to_hermes_field(property, key in required)}
    end)
  end

  def to_hermes(_schema), do: %{}

  @spec to_hermes_field(map() | term(), boolean()) :: term()
  def to_hermes_field(property, required?) when is_map(property) do
    type =
      case property do
        %{"type" => "string", "enum" => values} when is_list(values) ->
          {:enum, values, [type: :string]}

        %{"type" => "integer"} ->
          :integer

        %{"type" => "array", "items" => %{"type" => "string"}} ->
          {:list, :string}

        %{"type" => "object"} = nested ->
          case to_hermes(nested) do
            nested_fields when map_size(nested_fields) == 0 -> :any
            nested_fields -> {:object, nested_fields}
          end

        _ ->
          :any
      end

    if required?, do: {:required, type}, else: type
  end

  def to_hermes_field(_property, required?) do
    if required?, do: {:required, :any}, else: :any
  end
end

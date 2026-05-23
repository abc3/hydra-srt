defmodule HydraSrt.Mcp.Tools.Interfaces do
  @moduledoc false

  alias HydraSrt.Interfaces
  alias HydraSrt.Mcp.Helpers
  alias HydraSrt.Mcp.Tools.Routes, as: Schema

  @spec definitions() :: [map()]
  def definitions do
    [
      %{
        name: "list_interfaces",
        description: "List configured network interface aliases from the database.",
        input_schema: Schema.object_schema(%{})
      },
      %{
        name: "get_interface",
        description: "Get a configured interface by ID.",
        input_schema:
          Schema.object_schema(%{"interface_id" => Schema.string_prop("Interface ID")}, [
            "interface_id"
          ])
      },
      %{
        name: "create_interface",
        description: "Create a configured interface alias.",
        input_schema:
          Schema.object_schema(%{"interface" => Schema.object_prop("Interface attributes")}, [
            "interface"
          ])
      },
      %{
        name: "update_interface",
        description: "Update a configured interface alias.",
        input_schema:
          Schema.object_schema(
            %{
              "interface_id" => Schema.string_prop("Interface ID"),
              "interface" => Schema.object_prop("Interface attributes")
            },
            ["interface_id", "interface"]
          )
      },
      %{
        name: "delete_interface",
        description: "Delete a configured interface alias.",
        input_schema:
          Schema.object_schema(%{"interface_id" => Schema.string_prop("Interface ID")}, [
            "interface_id"
          ])
      },
      %{
        name: "list_system_interfaces",
        description:
          "List OS network interfaces parsed from ifconfig (sys_name, ip, multicast_supported, raw_description).",
        input_schema: Schema.object_schema(%{})
      },
      %{
        name: "get_system_interface",
        description: "Look up one OS interface by sys_name from ifconfig.",
        input_schema:
          Schema.object_schema(%{"sys_name" => Schema.string_prop("OS interface name")}, [
            "sys_name"
          ])
      },
      %{
        name: "get_system_interfaces_raw",
        description: "Return raw ifconfig output.",
        input_schema: Schema.object_schema(%{})
      }
    ]
  end

  @spec handles?(String.t()) :: boolean()
  def handles?(name), do: name in Enum.map(definitions(), & &1.name)

  @spec call(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call("list_interfaces", _args) do
    case Interfaces.list() do
      {:ok, interfaces} -> {:ok, Helpers.ok(interfaces)}
      error -> {:ok, Helpers.from_result(error)}
    end
  end

  def call("get_interface", args) do
    with {:ok, interface_id} <- Schema.param(args, "interface_id"),
         result <- Interfaces.get(interface_id) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call("create_interface", args) do
    with {:ok, interface} <- Schema.map_param(args, "interface"),
         result <- Interfaces.create(interface) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call("update_interface", args) do
    with {:ok, interface_id} <- Schema.param(args, "interface_id"),
         {:ok, interface} <- Schema.map_param(args, "interface"),
         result <- Interfaces.update(interface_id, interface) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call("delete_interface", args) do
    with {:ok, interface_id} <- Schema.param(args, "interface_id") do
      case Interfaces.delete(interface_id) do
        :ok -> {:ok, Helpers.ok(%{"deleted" => true, "interface_id" => interface_id})}
        error -> {:ok, Helpers.from_result(error)}
      end
    end
  end

  def call("list_system_interfaces", _args) do
    case Interfaces.list_system() do
      {:ok, interfaces} -> {:ok, Helpers.ok(interfaces)}
      {:error, message} -> {:ok, Helpers.from_result({:error, message})}
    end
  end

  def call("get_system_interface", args) do
    with {:ok, sys_name} <- Schema.param(args, "sys_name"),
         result <- Interfaces.get_system(sys_name) do
      case result do
        {:ok, interface} -> {:ok, Helpers.ok(interface)}
        {:error, message} -> {:ok, Helpers.from_result({:error, message})}
      end
    end
  end

  def call("get_system_interfaces_raw", _args) do
    case Interfaces.system_raw() do
      {:ok, raw} -> {:ok, Helpers.ok(%{"raw" => raw})}
      {:error, message} -> {:ok, Helpers.from_result({:error, message})}
    end
  end

  def call(_name, _args), do: :unknown
end

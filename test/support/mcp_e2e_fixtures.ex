defmodule HydraSrt.TestSupport.McpE2EFixtures do
  @moduledoc false

  import HydraSrt.DbFixtures

  alias HydraSrt.Db
  alias HydraSrt.Nodes

  @type context :: %{
          suffix: String.t(),
          route_id: String.t(),
          source_id: String.t(),
          source2_id: String.t(),
          destination_id: String.t(),
          tag_id: String.t(),
          interface_id: String.t(),
          node_id: String.t(),
          loopback_sys_name: String.t()
        }

  @spec seed_context!() :: context()
  def seed_context! do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    route = route_fixture(%{"name" => "mcp-e2e-route-#{suffix}", "enabled" => false})
    source = source_fixture(route, %{"name" => "mcp-e2e-source-1", "position" => 0})
    source2 = source_fixture(route, %{"name" => "mcp-e2e-source-2", "position" => 1})
    destination = destination_fixture(route, %{"name" => "mcp-e2e-destination-#{suffix}"})
    {:ok, tag} = Db.create_tag(%{"name" => "mcp-e2e-tag-#{suffix}"})

    {:ok, interface} =
      Db.create_interface(%{
        "name" => "mcp-e2e-interface-#{suffix}",
        "sys_name" => "mcp-e2e-lo-#{suffix}",
        "ip" => "127.0.0.1",
        "enabled" => true
      })

    stats = Nodes.self_stats()
    node_id = to_string(stats[:host] || stats["host"] || node())

    %{
      suffix: suffix,
      route_id: route["id"],
      source_id: source["id"],
      source2_id: source2["id"],
      destination_id: destination["id"],
      tag_id: tag.id,
      interface_id: interface["id"],
      node_id: node_id,
      loopback_sys_name: loopback_sys_name()
    }
  end

  @spec loopback_sys_name() :: String.t()
  def loopback_sys_name do
    case :os.type() do
      {:unix, :darwin} -> "lo0"
      _ -> "lo"
    end
  end

  @spec disposable_route_name(context()) :: String.t()
  def disposable_route_name(%{suffix: suffix}), do: "mcp-e2e-disposable-route-#{suffix}"

  @spec disposable_tag_name(context()) :: String.t()
  def disposable_tag_name(%{suffix: suffix}), do: "mcp-e2e-disposable-tag-#{suffix}"

  @spec disposable_interface_name(context()) :: String.t()
  def disposable_interface_name(%{suffix: suffix}),
    do: "mcp-e2e-disposable-interface-#{suffix}"
end

defmodule HydraSrt.Mcp.Tools.InterfacesTest do
  use ExUnit.Case, async: false

  alias HydraSrt.Mcp.Tools.Interfaces
  alias HydraSrt.SystemInterfaces

  test "get_system_interface returns parsed interface by sys_name" do
    output = """
    lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
    \tinet 127.0.0.1 netmask 0xff000000
    en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
    \tinet 172.20.20.12 netmask 0xffffff00 broadcast 172.20.20.255
    """

    expected = SystemInterfaces.parse_ifconfig(output)

    with_mock_discover(expected, fn ->
      assert {:ok, response} = Interfaces.call("get_system_interface", %{"sys_name" => "en0"})
      assert response.structured_content["data"]["sys_name"] == "en0"
      assert response.structured_content["data"]["ip"] == "172.20.20.12/24"
    end)
  end

  test "get_system_interface returns not found error" do
    with_mock_discover([], fn ->
      assert {:ok, response} =
               Interfaces.call("get_system_interface", %{"sys_name" => "missing0"})

      assert response.isError == true
      assert response.structured_content["error"] =~ "not found"
    end)
  end

  test "get_system_interface returns missing sys_name error" do
    assert {:error, response} = Interfaces.call("get_system_interface", %{})
    assert response.isError == true
    assert response.structured_content["error"] =~ "sys_name"
  end

  def with_mock_discover(interfaces, fun) do
    :meck.new(SystemInterfaces, [:passthrough])
    :meck.expect(SystemInterfaces, :discover, fn -> {:ok, interfaces} end)

    try do
      fun.()
    after
      :meck.unload(SystemInterfaces)
    end
  end
end

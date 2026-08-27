defmodule HydraSrt.Api.EndpointSourceTest do
  use HydraSrt.DataCase

  alias HydraSrt.Api.Endpoint
  alias HydraSrt.Repo

  import HydraSrt.ApiFixtures

  test "valid changeset with required fields" do
    route = route_fixture()

    changeset =
      Endpoint.source_changeset(%Endpoint{}, %{
        route_id: route.id,
        position: 0,
        schema: "UDP",
        host: "127.0.0.1",
        port: 5000
      })

    assert changeset.valid?
  end

  test "invalid when schema missing" do
    route = route_fixture()
    changeset = Endpoint.source_changeset(%Endpoint{}, %{route_id: route.id, position: 0})
    refute changeset.valid?
    assert {"can't be blank", _} = changeset.errors[:schema]
  end

  test "invalid schema value" do
    route = route_fixture()

    changeset =
      Endpoint.source_changeset(%Endpoint{}, %{route_id: route.id, position: 0, schema: "INVALID"})

    refute changeset.valid?
    assert {"is invalid", _} = changeset.errors[:schema]
  end

  test "RTP source schema is valid" do
    route = route_fixture()

    changeset =
      Endpoint.source_changeset(%Endpoint{}, %{
        route_id: route.id,
        position: 0,
        schema: "RTP",
        address: "127.0.0.1",
        port: 5000
      })

    assert changeset.valid?
  end

  test "invalid negative position" do
    route = route_fixture()

    changeset =
      Endpoint.source_changeset(%Endpoint{}, %{route_id: route.id, position: -1, schema: "UDP"})

    refute changeset.valid?
    assert {"must be greater than or equal to %{number}", _} = changeset.errors[:position]
  end

  test "unique constraint route_id + position" do
    route = route_fixture()
    _ = source_fixture(route, %{position: 0})

    assert {:error, changeset} =
             %Endpoint{}
             |> Endpoint.source_changeset(%{
               route_id: route.id,
               position: 0,
               schema: "SRT",
               host: "127.0.0.1",
               port: 5001
             })
             |> Repo.insert()

    assert {"has already been taken", _} = changeset.errors[:route_id]
  end

  test "rejects duplicate UDP bind target across endpoints" do
    route = route_fixture()

    _ =
      source_fixture(route, %{
        schema: "UDP",
        address: "127.0.0.1",
        port: 5050
      })

    assert {:error, changeset} =
             %Endpoint{}
             |> Endpoint.source_changeset(%{
               route_id: route.id,
               position: 2,
               schema: "UDP",
               interface_sys_name: "",
               address: "127.0.0.1",
               port: 5050
             })
             |> Repo.insert()

    {message, _meta} = changeset.errors[:bind_port]

    assert message == "bind target is already in use"
  end

  test "allows multicast sources to share an interface and port when the groups differ" do
    route = route_fixture()

    assert {:ok, first} =
             %Endpoint{}
             |> Endpoint.source_changeset(%{
               route_id: route.id,
               position: 10,
               schema: "UDP",
               interface_sys_name: "enp23s0f1",
               multicast: true,
               address: "239.58.0.46",
               port: 50_001
             })
             |> Repo.insert()

    assert first.bind_multicast_group == "239.58.0.46"

    assert {:ok, second} =
             %Endpoint{}
             |> Endpoint.source_changeset(%{
               route_id: route.id,
               position: 11,
               schema: "UDP",
               interface_sys_name: "enp23s0f1",
               multicast: true,
               address: "239.58.0.47",
               port: 50_001
             })
             |> Repo.insert()

    assert second.bind_multicast_group == "239.58.0.47"
    assert second.bind_port == first.bind_port
  end

  test "allows RTP multicast sources to share an interface and port when the groups differ" do
    route = route_fixture()

    assert {:ok, _} =
             %Endpoint{}
             |> Endpoint.source_changeset(%{
               route_id: route.id,
               position: 12,
               schema: "RTP",
               interface_sys_name: "enp23s0f1",
               multicast: true,
               address: "239.60.0.1",
               port: 50_002
             })
             |> Repo.insert()

    assert {:ok, _} =
             %Endpoint{}
             |> Endpoint.source_changeset(%{
               route_id: route.id,
               position: 13,
               schema: "RTP",
               interface_sys_name: "enp23s0f1",
               multicast: true,
               address: "239.60.0.2",
               port: 50_002
             })
             |> Repo.insert()
  end

  test "rejects a second multicast source on the same interface, group and port" do
    route = route_fixture()

    _ =
      source_fixture(route, %{
        schema: "UDP",
        interface_sys_name: "enp23s0f1",
        multicast: true,
        address: "239.58.0.46",
        port: 50_003
      })

    assert {:error, changeset} =
             %Endpoint{}
             |> Endpoint.source_changeset(%{
               route_id: route.id,
               position: 14,
               schema: "UDP",
               interface_sys_name: "enp23s0f1",
               multicast: true,
               address: "239.58.0.46",
               port: 50_003
             })
             |> Repo.insert()

    {message, _meta} = changeset.errors[:bind_port]
    assert message == "bind target is already in use"
  end

  test "rejects unicast sources sharing an interface and port even with different addresses" do
    route = route_fixture()

    _ =
      source_fixture(route, %{
        schema: "UDP",
        interface_sys_name: "enp23s0f1",
        address: "192.168.23.15",
        port: 50_004
      })

    assert {:error, changeset} =
             %Endpoint{}
             |> Endpoint.source_changeset(%{
               route_id: route.id,
               position: 15,
               schema: "UDP",
               interface_sys_name: "enp23s0f1",
               address: "192.168.23.16",
               port: 50_004
             })
             |> Repo.insert()

    {message, _meta} = changeset.errors[:bind_port]
    assert message == "bind target is already in use"
  end

  test "treats an IPv6 group as multicast and a hostname as an ordinary bind" do
    route = route_fixture()

    assert {:ok, ipv6} =
             %Endpoint{}
             |> Endpoint.source_changeset(%{
               route_id: route.id,
               position: 16,
               schema: "UDP",
               interface_sys_name: "enp23s0f1",
               multicast: true,
               address: "ff3e::4321:1234",
               port: 50_005
             })
             |> Repo.insert()

    assert ipv6.bind_multicast_group == "ff3e::4321:1234"

    assert {:ok, hostname} =
             %Endpoint{}
             |> Endpoint.source_changeset(%{
               route_id: route.id,
               position: 17,
               schema: "UDP",
               interface_sys_name: "enp23s0f1",
               address: "feed.example.com",
               port: 50_006
             })
             |> Repo.insert()

    assert hostname.bind_multicast_group == nil
    assert hostname.bind_port == 50_006
  end

  test "rejects a second listener on the same interface and port regardless of typed address" do
    route = route_fixture()

    _ =
      source_fixture(route, %{
        schema: "SRT",
        mode: "listener",
        interface_sys_name: "eth0",
        localaddress: "127.0.0.1",
        localport: 4401
      })

    # The runtime binds to eth0's own address and ignores what was typed here, so both of
    # these end up on the same socket.
    assert {:error, changeset} =
             %Endpoint{}
             |> Endpoint.source_changeset(%{
               route_id: route.id,
               position: 3,
               schema: "SRT",
               mode: "listener",
               interface_sys_name: "eth0",
               localaddress: "0.0.0.0",
               localport: 4401
             })
             |> Repo.insert()

    {message, _meta} = changeset.errors[:bind_port]
    assert message == "bind target is already in use"
  end

  test "allows the same port on different interfaces" do
    route = route_fixture()

    _ =
      source_fixture(route, %{
        schema: "SRT",
        mode: "listener",
        interface_sys_name: "eth0",
        localport: 4402
      })

    assert {:ok, _} =
             %Endpoint{}
             |> Endpoint.source_changeset(%{
               route_id: route.id,
               position: 4,
               schema: "SRT",
               mode: "listener",
               interface_sys_name: "eth1",
               localport: 4402
             })
             |> Repo.insert()
  end

  test "detects duplicate bind target when existing endpoint has empty local fields but address/port set" do
    route = route_fixture()

    _ =
      source_fixture(route, %{
        schema: "UDP",
        localaddress: "",
        localport: nil,
        address: "10.0.0.8",
        port: 7000
      })

    assert {:error, changeset} =
             %Endpoint{}
             |> Endpoint.source_changeset(%{
               route_id: route.id,
               position: 5,
               schema: "UDP",
               address: "10.0.0.8",
               port: 7000
             })
             |> Repo.insert()

    {message, _meta} = changeset.errors[:bind_port]
    assert message == "bind target is already in use"
  end

  test "allows updating source without self-conflict when bind target is unchanged" do
    route = route_fixture()

    source =
      source_fixture(route, %{
        schema: "UDP",
        address: "127.0.0.1",
        port: 5100
      })

    assert {:ok, updated} =
             source
             |> Endpoint.source_changeset(%{
               name: "Updated source name",
               address: "127.0.0.1",
               port: 5100
             })
             |> Repo.update()

    assert updated.name == "Updated source name"
  end

  test "returns validation error (not crash) on non-numeric port values in schema options" do
    route = route_fixture()

    changeset =
      Endpoint.source_changeset(%Endpoint{}, %{
        route_id: route.id,
        position: 10,
        schema: "UDP",
        address: "127.0.0.1",
        port: "8080-tcp"
      })

    refute changeset.valid?
    assert {"is invalid", _} = changeset.errors[:port]
  end
end

defmodule HydraSrt.Api.EndpointDestinationTest do
  use HydraSrt.DataCase

  alias HydraSrt.Api.Endpoint
  alias HydraSrt.Repo

  import HydraSrt.ApiFixtures

  test "valid destination changeset with required fields" do
    route = route_fixture()

    changeset =
      Endpoint.destination_changeset(%Endpoint{}, %{
        route_id: route.id,
        schema: "UDP",
        host: "127.0.0.1",
        port: 5000
      })

    assert changeset.valid?
  end

  test "invalid RTMP destination changeset when location is missing" do
    route = route_fixture()

    changeset =
      Endpoint.destination_changeset(%Endpoint{}, %{
        route_id: route.id,
        schema: "RTMP"
      })

    refute changeset.valid?
    assert {"can't be blank", _} = changeset.errors[:location]
  end

  test "valid RTMP destination changeset with location" do
    route = route_fixture()

    changeset =
      Endpoint.destination_changeset(%Endpoint{}, %{
        route_id: route.id,
        schema: "RTMP",
        location: "rtmp://127.0.0.1:1935/live/stream"
      })

    assert changeset.valid?
  end

  test "invalid destination changeset when schema is missing" do
    route = route_fixture()
    changeset = Endpoint.destination_changeset(%Endpoint{}, %{route_id: route.id})
    refute changeset.valid?
    assert {"can't be blank", _} = changeset.errors[:schema]
  end

  test "destination unique constraint route_id + position + type returns changeset error" do
    route = route_fixture()

    _ =
      destination_fixture(route, %{
        position: 0,
        schema: "UDP",
        host: "127.0.0.1",
        port: 5000
      })

    assert {:error, changeset} =
             %Endpoint{}
             |> Endpoint.destination_changeset(%{
               route_id: route.id,
               position: 0,
               schema: "UDP",
               host: "127.0.0.1",
               port: 5001
             })
             |> Repo.insert()

    assert {"has already been taken", _} =
             changeset.errors[:route_id] || changeset.errors[:position]
  end

  test "rejects duplicate SRT listener bind target across endpoints" do
    route = route_fixture()

    _ =
      source_fixture(route, %{
        schema: "SRT",
        mode: "listener",
        localaddress: "0.0.0.0",
        localport: 6000
      })

    assert {:error, changeset} =
             %Endpoint{}
             |> Endpoint.destination_changeset(%{
               route_id: route.id,
               position: 9,
               schema: "SRT",
               mode: "listener",
               localaddress: "0.0.0.0",
               localport: 6000
             })
             |> Repo.insert()

    {message, _meta} = changeset.errors[:bind_port]
    assert message == "bind target is already in use"
  end

  test "does not reserve a bind target for a UDP destination that only names a remote host" do
    route_a = route_fixture()
    route_b = route_fixture()

    first =
      destination_fixture(route_a, %{
        schema: "UDP",
        interface_sys_name: "eth0",
        host: "127.0.0.1",
        port: 12_323
      })

    assert first.bind_port == nil

    assert {:ok, second} =
             %Endpoint{}
             |> Endpoint.destination_changeset(%{
               route_id: route_b.id,
               position: 3,
               schema: "UDP",
               interface_sys_name: "eth0",
               host: "127.0.0.1",
               port: 12_323
             })
             |> Repo.insert()

    assert second.bind_port == nil
  end

  test "rejects UDP destinations that bind the same local interface and port" do
    route_a = route_fixture()
    route_b = route_fixture()

    _ =
      destination_fixture(route_a, %{
        schema: "UDP",
        interface_sys_name: "eth0",
        host: "127.0.0.1",
        port: 12_400,
        localport: 12_401
      })

    assert {:error, changeset} =
             %Endpoint{}
             |> Endpoint.destination_changeset(%{
               route_id: route_b.id,
               position: 4,
               schema: "UDP",
               interface_sys_name: "eth0",
               host: "127.0.0.2",
               port: 12_402,
               localport: 12_401
             })
             |> Repo.insert()

    {message, _meta} = changeset.errors[:bind_port]
    assert message == "bind target is already in use"
  end

  test "keys a bound UDP destination on its local port, not the port it sends to" do
    route = route_fixture()

    destination =
      destination_fixture(route, %{
        schema: "UDP",
        interface_sys_name: "eth0",
        host: "239.1.1.1",
        port: 12_500,
        localaddress: "192.168.23.15",
        localport: 12_501
      })

    assert destination.bind_port == 12_501
    assert destination.bind_address == "192.168.23.15"
    assert destination.bind_multicast_group == nil
  end

  test "allows updating destination without self-conflict when bind target is unchanged" do
    route = route_fixture()

    destination =
      destination_fixture(route, %{
        schema: "SRT",
        mode: "listener",
        localaddress: "0.0.0.0",
        localport: 6200
      })

    assert {:ok, updated} =
             destination
             |> Endpoint.destination_changeset(%{
               name: "Updated destination name",
               mode: "listener",
               localaddress: "0.0.0.0",
               localport: 6200
             })
             |> Repo.update()

    assert updated.name == "Updated destination name"
  end
end

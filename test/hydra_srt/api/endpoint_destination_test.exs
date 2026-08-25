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

  test "rejects duplicate UDP destination target across routes when interface/address/port match" do
    route_a = route_fixture()
    route_b = route_fixture()

    _ =
      destination_fixture(route_a, %{
        schema: "UDP",
        interface_sys_name: "eth0",
        host: "127.0.0.1",
        port: 12_323
      })

    assert {:error, changeset} =
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

    {message, _meta} = changeset.errors[:bind_port]
    assert message == "bind target is already in use"
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

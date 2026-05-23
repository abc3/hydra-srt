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

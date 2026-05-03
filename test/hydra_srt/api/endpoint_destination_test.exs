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
        schema_options: %{"host" => "127.0.0.1", "port" => 5000}
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
        schema_options: %{"host" => "127.0.0.1", "port" => 5000}
      })

    assert {:error, changeset} =
             %Endpoint{}
             |> Endpoint.destination_changeset(%{
               route_id: route.id,
               position: 0,
               schema: "UDP",
               schema_options: %{"host" => "127.0.0.1", "port" => 5001}
             })
             |> Repo.insert()

    assert {"has already been taken", _} =
             changeset.errors[:route_id] || changeset.errors[:position]
  end
end

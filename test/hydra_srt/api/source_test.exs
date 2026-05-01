defmodule HydraSrt.Api.SourceTest do
  use HydraSrt.DataCase

  alias HydraSrt.Api.Source
  alias HydraSrt.Repo

  import HydraSrt.ApiFixtures

  test "valid changeset with required fields" do
    route = route_fixture()

    changeset =
      Source.changeset(%Source{}, %{
        route_id: route.id,
        position: 0,
        schema: "UDP",
        schema_options: %{"host" => "127.0.0.1", "port" => 5000}
      })

    assert changeset.valid?
  end

  test "invalid when schema missing" do
    route = route_fixture()
    changeset = Source.changeset(%Source{}, %{route_id: route.id, position: 0})
    refute changeset.valid?
    assert {"can't be blank", _} = changeset.errors[:schema]
  end

  test "invalid schema value" do
    route = route_fixture()
    changeset = Source.changeset(%Source{}, %{route_id: route.id, position: 0, schema: "RTP"})
    refute changeset.valid?
    assert {"is invalid", _} = changeset.errors[:schema]
  end

  test "invalid negative position" do
    route = route_fixture()
    changeset = Source.changeset(%Source{}, %{route_id: route.id, position: -1, schema: "UDP"})
    refute changeset.valid?
    assert {"must be greater than or equal to %{number}", _} = changeset.errors[:position]
  end

  test "unique constraint route_id + position" do
    route = route_fixture()
    _ = source_fixture(route, %{position: 0})

    assert {:error, changeset} =
             %Source{}
             |> Source.changeset(%{
               route_id: route.id,
               position: 0,
               schema: "SRT",
               schema_options: %{"host" => "127.0.0.1", "port" => 5001}
             })
             |> Repo.insert()

    assert {"has already been taken", _} = changeset.errors[:route_id]
  end
end

defmodule HydraSrt.Api.EndpointTest do
  use ExUnit.Case

  alias HydraSrt.Api.Endpoint
  alias HydraSrt.Db

  test "source changeset stores access lists as JSON and defaults limit_access" do
    changeset =
      Endpoint.source_changeset(%Endpoint{}, %{
        "route_id" => Ecto.UUID.generate(),
        "position" => 0,
        "schema" => "SRT",
        "mode" => "listener",
        "allowed_list" => [" 127.0.0.1 ", "10.10.0.0/16", ""],
        "denied_list" => ["192.0.2.10"]
      })

    assert changeset.valid?

    assert Jason.decode!(Ecto.Changeset.get_change(changeset, :allowed_list)) == [
             "127.0.0.1",
             "10.10.0.0/16"
           ]

    assert Jason.decode!(Ecto.Changeset.get_change(changeset, :denied_list)) == ["192.0.2.10"]
    assert Ecto.Changeset.get_field(changeset, :limit_access) == false
  end

  test "source changeset accepts IPv6 CIDR access list entries" do
    changeset =
      Endpoint.source_changeset(%Endpoint{}, %{
        "route_id" => Ecto.UUID.generate(),
        "position" => 0,
        "schema" => "SRT",
        "mode" => "listener",
        "limit_access" => true,
        "allowed_list" => ["2001:db8::/32"],
        "denied_list" => ["fe80::1"]
      })

    assert changeset.valid?
  end

  test "source changeset rejects malformed access list entries" do
    changeset =
      Endpoint.source_changeset(%Endpoint{}, %{
        "route_id" => Ecto.UUID.generate(),
        "position" => 0,
        "schema" => "SRT",
        "mode" => "listener",
        "limit_access" => true,
        "allowed_list" => ["not-an-ip"]
      })

    refute changeset.valid?

    assert {"must contain only IP addresses or CIDR ranges", _} =
             changeset.errors[:allowed_list]
  end

  test "decode_ip_access_list returns API list values from stored JSON" do
    assert Endpoint.decode_ip_access_list(~s(["127.0.0.1","10.0.0.0/8"])) == [
             "127.0.0.1",
             "10.0.0.0/8"
           ]
  end

  test "source_to_map returns access lists as arrays" do
    source = %Endpoint{
      id: Ecto.UUID.generate(),
      route_id: Ecto.UUID.generate(),
      enabled: true,
      schema: "SRT",
      allowed_list: ~s(["127.0.0.1"]),
      denied_list: ~s(["192.0.2.10"]),
      limit_access: true
    }

    mapped = Db.source_to_map(source)

    assert mapped["allowed_list"] == ["127.0.0.1"]
    assert mapped["denied_list"] == ["192.0.2.10"]
    assert mapped["limit_access"] == true
  end
end

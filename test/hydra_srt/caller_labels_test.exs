defmodule HydraSrt.CallerLabelsTest do
  use HydraSrt.DataCase

  alias HydraSrt.Api.CallerLabel
  alias HydraSrt.CallerLabels
  alias HydraSrt.Repo

  test "exact address wins over CIDR and longest CIDR prefix wins" do
    assert {:ok, _} = CallerLabels.create(%{"address" => "10.0.0.0/8", "label" => "network"})
    assert {:ok, _} = CallerLabels.create(%{"address" => "10.1.0.0/16", "label" => "region"})
    assert {:ok, _} = CallerLabels.create(%{"address" => "10.1.2.0/24", "label" => "site"})
    assert {:ok, _} = CallerLabels.create(%{"address" => "10.1.2.3", "label" => "caller"})

    assert CallerLabels.label_for_ip("10.1.2.3") == "caller"
    assert CallerLabels.label_for_ip("10.1.2.99") == "site"
    assert CallerLabels.label_for_ip("10.9.0.1") == "network"
  end

  test "label_for_ip supports IPv6" do
    assert {:ok, _} = CallerLabels.create(%{"address" => "2001:db8::/32", "label" => "docs"})
    assert {:ok, _} = CallerLabels.create(%{"address" => "2001:db8:1::/48", "label" => "lab"})

    assert CallerLabels.label_for_ip("2001:db8:1::42") == "lab"
    assert CallerLabels.label_for_ip("2001:db8:2::42") == "docs"
  end

  test "changeset rejects malformed addresses and empty labels" do
    changeset = CallerLabel.changeset(%CallerLabel{}, %{"address" => "not-an-ip", "label" => " "})

    refute changeset.valid?
    assert changeset.errors[:address]
    assert changeset.errors[:label]
  end

  test "unparseable stored addresses are skipped" do
    now = DateTime.utc_now()

    Repo.insert_all("caller_labels", [
      %{
        id: Ecto.UUID.dump!(Ecto.UUID.generate()),
        address: "not-an-ip",
        label: "invalid",
        inserted_at: now,
        updated_at: now
      }
    ])

    CallerLabels.invalidate()
    assert CallerLabels.label_for_ip("203.0.113.5") == nil
  end
end

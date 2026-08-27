defmodule HydraSrt.Repo.Migrations.AddMulticastGroupToBindIdentity do
  use Ecto.Migration

  @moduledoc """
  Puts the multicast group into the bind-target key, and stops treating a plain UDP destination
  as if it owned a port.

  Releasing those destination reservations is not reversible: `down/0` restores the old indexes,
  not the old reservations.
  """

  @multicast_index :endpoints_bind_interface_bind_multicast_group_bind_port_index

  def up do
    alter table(:endpoints) do
      add :bind_multicast_group, :string
    end

    drop_if_exists(index(:endpoints, [:bind_interface, :bind_port]))
    drop_if_exists(index(:endpoints, [:bind_address, :bind_port]))

    execute("""
    UPDATE endpoints
    SET bind_multicast_group = bind_address
    WHERE bind_port IS NOT NULL
      AND type = 'source'
      AND schema IN ('UDP', 'RTP')
      AND bind_address IS NOT NULL
      AND trim(bind_address) <> ''
      AND (
        bind_address GLOB 'ff*'
        OR (
          substr(bind_address, 1, 1) GLOB '[0-9]'
          AND instr(bind_address, '.') > 1
          AND CAST(substr(bind_address, 1, instr(bind_address, '.') - 1) AS INTEGER)
              BETWEEN 224 AND 239
        )
      )
    """)

    execute("""
    UPDATE endpoints
    SET
      bind_interface = NULL,
      bind_address = NULL,
      bind_multicast_group = NULL,
      bind_port = NULL
    WHERE type = 'destination'
      AND schema = 'UDP'
      AND localport IS NULL
    """)

    execute("""
    UPDATE endpoints
    SET
      bind_address = lower(trim(coalesce(localaddress, ''))),
      bind_multicast_group = NULL,
      bind_port = localport
    WHERE type = 'destination'
      AND schema = 'UDP'
      AND localport IS NOT NULL
    """)

    dedupe_bind_targets("bind_interface, bind_multicast_group", multicast_bound_where())
    dedupe_bind_targets("bind_interface", interface_bound_where())
    dedupe_bind_targets("bind_address", address_bound_where())

    create unique_index(:endpoints, [:bind_interface, :bind_multicast_group, :bind_port],
             where: multicast_bound_where()
           )

    create unique_index(:endpoints, [:bind_interface, :bind_port], where: interface_bound_where())

    create unique_index(:endpoints, [:bind_address, :bind_port], where: address_bound_where())
  end

  def down do
    drop_if_exists(
      index(:endpoints, [:bind_interface, :bind_multicast_group, :bind_port],
        name: @multicast_index
      )
    )

    drop_if_exists(index(:endpoints, [:bind_interface, :bind_port]))
    drop_if_exists(index(:endpoints, [:bind_address, :bind_port]))

    dedupe_bind_targets("bind_interface", legacy_interface_bound_where())
    dedupe_bind_targets("bind_address", legacy_address_bound_where())

    create unique_index(:endpoints, [:bind_interface, :bind_port],
             where: legacy_interface_bound_where()
           )

    create unique_index(:endpoints, [:bind_address, :bind_port],
             where: legacy_address_bound_where()
           )

    alter table(:endpoints) do
      remove :bind_multicast_group
    end
  end

  def multicast_bound_where do
    "bind_port IS NOT NULL AND bind_interface IS NOT NULL AND trim(bind_interface) <> '' " <>
      "AND bind_multicast_group IS NOT NULL AND trim(bind_multicast_group) <> ''"
  end

  def interface_bound_where do
    "bind_port IS NOT NULL AND bind_interface IS NOT NULL AND trim(bind_interface) <> '' " <>
      "AND (bind_multicast_group IS NULL OR trim(bind_multicast_group) = '')"
  end

  def address_bound_where do
    "bind_port IS NOT NULL AND (bind_interface IS NULL OR trim(bind_interface) = '')"
  end

  def legacy_interface_bound_where do
    "bind_port IS NOT NULL AND bind_interface IS NOT NULL AND trim(bind_interface) <> ''"
  end

  def legacy_address_bound_where do
    "bind_port IS NOT NULL AND (bind_interface IS NULL OR trim(bind_interface) = '')"
  end

  def dedupe_bind_targets(partition_columns, where_clause) do
    execute("""
    WITH ranked AS (
      SELECT
        id,
        ROW_NUMBER() OVER (
          PARTITION BY #{partition_columns}, bind_port
          ORDER BY inserted_at ASC, id ASC
        ) AS rn
      FROM endpoints
      WHERE #{where_clause}
    )
    UPDATE endpoints
    SET
      bind_interface = NULL,
      bind_address = NULL,
      bind_multicast_group = NULL,
      bind_port = NULL
    WHERE id IN (
      SELECT id
      FROM ranked
      WHERE rn > 1
    )
    """)
  end
end

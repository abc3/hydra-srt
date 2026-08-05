defmodule HydraSrt.Repo.Migrations.SplitBindTargetUniqueIndex do
  use Ecto.Migration

  @moduledoc """
  Splits the bind-target uniqueness rule in two, so each kind of endpoint is keyed on what
  actually decides its socket.

  An endpoint that names an interface is resolved to that interface's own address at runtime
  (`RouteHandler.resolve_interface_options/1`) and the address stored on the row is discarded.
  Keying such a row on the stored address let two listeners share one interface and port
  without the index noticing. Those rows are now keyed on interface + port; rows that bind to
  a literal address keep being keyed on address + port.
  """

  def up do
    drop_if_exists(index(:endpoints, [:bind_interface, :bind_address, :bind_port]))

    dedupe_bind_targets("bind_interface", interface_bound_where())
    dedupe_bind_targets("bind_address", address_bound_where())

    create unique_index(:endpoints, [:bind_interface, :bind_port], where: interface_bound_where())

    create unique_index(:endpoints, [:bind_address, :bind_port], where: address_bound_where())
  end

  def down do
    drop_if_exists(index(:endpoints, [:bind_interface, :bind_port]))
    drop_if_exists(index(:endpoints, [:bind_address, :bind_port]))

    dedupe_bind_targets("bind_interface, bind_address", "bind_port IS NOT NULL")

    create unique_index(:endpoints, [:bind_interface, :bind_address, :bind_port],
             where: "bind_port IS NOT NULL"
           )
  end

  def interface_bound_where do
    "bind_port IS NOT NULL AND bind_interface IS NOT NULL AND trim(bind_interface) <> ''"
  end

  def address_bound_where do
    "bind_port IS NOT NULL AND (bind_interface IS NULL OR trim(bind_interface) = '')"
  end

  # Rows that the old, laxer key let through can now collide. Keep the oldest of each group
  # bound and release the rest, the same way the original bind-target migration resolved
  # historical duplicates.
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
      bind_port = NULL
    WHERE id IN (
      SELECT id
      FROM ranked
      WHERE rn > 1
    )
    """)
  end
end

defmodule HydraSrt.Repo.Migrations.AddBindTargetColumnsToEndpoints do
  use Ecto.Migration

  def up do
    alter table(:endpoints) do
      add :mode, :string
      add :interface_sys_name, :string
      add :localaddress, :string
      add :localport, :integer
      add :address, :string
      add :port, :integer
      add :host, :string
      add :latency, :integer
      add :authentication, :boolean
      add :passphrase, :string
      add :pbkeylen, :integer
      add :poll_timeout, :integer
      add :auto_reconnect, :boolean
      add :keep_listening, :boolean
      add :multicast_iface, :string
      add :bind_address_option, :string
      add :bind_interface, :string
      add :bind_address, :string
      add :bind_port, :integer
    end

    execute("""
    UPDATE endpoints
    SET
      bind_interface = CASE
        WHEN should_bind = 1 THEN normalized_interface
        ELSE NULL
      END,
      bind_address = CASE
        WHEN should_bind = 1 THEN normalized_address
        ELSE NULL
      END,
      bind_port = CASE
        WHEN should_bind = 1 THEN normalized_port
        ELSE NULL
      END,
      mode = nullif(mode_raw, ''),
      interface_sys_name = nullif(interface_sys_name_raw, ''),
      localaddress = nullif(local_address_raw, ''),
      localport = parsed_local_port,
      address = nullif(remote_address_raw, ''),
      port = parsed_remote_port,
      host = nullif(host_address_raw, ''),
      latency = parsed_latency,
      authentication = parsed_authentication,
      passphrase = nullif(passphrase_raw, ''),
      pbkeylen = parsed_pbkeylen,
      poll_timeout = parsed_poll_timeout,
      auto_reconnect = parsed_auto_reconnect,
      keep_listening = parsed_keep_listening,
      multicast_iface = nullif(multicast_iface_raw, ''),
      bind_address_option = nullif(bind_address_raw, '')
    FROM (
      SELECT
        id,
        CASE
          WHEN schema = 'SRT' AND mode IN ('listener', 'rendezvous') THEN 1
          WHEN schema = 'UDP' AND type = 'source' THEN 1
          WHEN schema = 'UDP' AND type = 'destination' AND local_port_present = 1 THEN 1
          ELSE 0
        END AS should_bind,
        lower(trim(coalesce(interface_sys_name, ''))) AS normalized_interface,
        lower(trim(coalesce(local_address, remote_address, host_address, ''))) AS normalized_address,
        CASE
          WHEN local_port_candidate GLOB '[0-9]*' AND local_port_candidate <> '' THEN CAST(local_port_candidate AS INTEGER)
          WHEN remote_port_candidate GLOB '[0-9]*' AND remote_port_candidate <> '' THEN CAST(remote_port_candidate AS INTEGER)
          ELSE NULL
        END AS normalized_port,
        mode_raw,
        interface_sys_name_raw,
        local_address_raw,
        remote_address_raw,
        host_address_raw,
        passphrase_raw,
        multicast_iface_raw,
        bind_address_raw,
        CASE
          WHEN local_port_candidate GLOB '[0-9]*' AND local_port_candidate <> '' THEN CAST(local_port_candidate AS INTEGER)
          ELSE NULL
        END AS parsed_local_port,
        CASE
          WHEN remote_port_candidate GLOB '[0-9]*' AND remote_port_candidate <> '' THEN CAST(remote_port_candidate AS INTEGER)
          ELSE NULL
        END AS parsed_remote_port,
        CASE
          WHEN latency_candidate GLOB '[0-9]*' AND latency_candidate <> '' THEN CAST(latency_candidate AS INTEGER)
          ELSE NULL
        END AS parsed_latency,
        CASE
          WHEN pbkeylen_candidate GLOB '[0-9]*' AND pbkeylen_candidate <> '' THEN CAST(pbkeylen_candidate AS INTEGER)
          ELSE NULL
        END AS parsed_pbkeylen,
        CASE
          WHEN poll_timeout_candidate GLOB '[0-9]*' AND poll_timeout_candidate <> '' THEN CAST(poll_timeout_candidate AS INTEGER)
          ELSE NULL
        END AS parsed_poll_timeout,
        CASE
          WHEN authentication_raw IN ('true', '1') THEN 1
          WHEN authentication_raw IN ('false', '0') THEN 0
          ELSE NULL
        END AS parsed_authentication,
        CASE
          WHEN auto_reconnect_raw IN ('true', '1') THEN 1
          WHEN auto_reconnect_raw IN ('false', '0') THEN 0
          ELSE NULL
        END AS parsed_auto_reconnect,
        CASE
          WHEN keep_listening_raw IN ('true', '1') THEN 1
          WHEN keep_listening_raw IN ('false', '0') THEN 0
          ELSE NULL
        END AS parsed_keep_listening
      FROM (
        SELECT
          e.id,
          e.schema,
          e.type,
          lower(trim(coalesce(json_extract(e.schema_options, '$.mode'), ''))) AS mode,
          lower(trim(coalesce(json_extract(e.schema_options, '$.mode'), ''))) AS mode_raw,
          trim(coalesce(json_extract(e.schema_options, '$.interface_sys_name'), '')) AS interface_sys_name,
          trim(coalesce(json_extract(e.schema_options, '$.interface_sys_name'), '')) AS interface_sys_name_raw,
          trim(coalesce(json_extract(e.schema_options, '$.localaddress'), '')) AS local_address,
          trim(coalesce(json_extract(e.schema_options, '$.localaddress'), '')) AS local_address_raw,
          trim(coalesce(json_extract(e.schema_options, '$.address'), '')) AS remote_address,
          trim(coalesce(json_extract(e.schema_options, '$.address'), '')) AS remote_address_raw,
          trim(coalesce(json_extract(e.schema_options, '$.host'), '')) AS host_address,
          trim(coalesce(json_extract(e.schema_options, '$.host'), '')) AS host_address_raw,
          trim(coalesce(CAST(json_extract(e.schema_options, '$.localport') AS TEXT), '')) AS local_port_candidate,
          trim(coalesce(CAST(json_extract(e.schema_options, '$.port') AS TEXT), '')) AS remote_port_candidate,
          trim(coalesce(CAST(json_extract(e.schema_options, '$.latency') AS TEXT), '')) AS latency_candidate,
          trim(coalesce(CAST(json_extract(e.schema_options, '$.pbkeylen') AS TEXT), '')) AS pbkeylen_candidate,
          trim(coalesce(CAST(json_extract(e.schema_options, '$.poll-timeout') AS TEXT), '')) AS poll_timeout_candidate,
          lower(trim(coalesce(CAST(json_extract(e.schema_options, '$.authentication') AS TEXT), ''))) AS authentication_raw,
          trim(coalesce(CAST(json_extract(e.schema_options, '$.passphrase') AS TEXT), '')) AS passphrase_raw,
          lower(trim(coalesce(CAST(json_extract(e.schema_options, '$.auto-reconnect') AS TEXT), ''))) AS auto_reconnect_raw,
          lower(trim(coalesce(CAST(json_extract(e.schema_options, '$.keep-listening') AS TEXT), ''))) AS keep_listening_raw,
          trim(coalesce(CAST(json_extract(e.schema_options, '$.multicast-iface') AS TEXT), '')) AS multicast_iface_raw,
          trim(coalesce(CAST(json_extract(e.schema_options, '$.bind-address') AS TEXT), '')) AS bind_address_raw,
          CASE
            WHEN trim(coalesce(CAST(json_extract(e.schema_options, '$.localport') AS TEXT), '')) <> '' THEN 1
            ELSE 0
          END AS local_port_present
        FROM endpoints e
      ) prepared
    ) resolved
    WHERE endpoints.id = resolved.id
    """)

    # Historical data may already contain duplicate bind targets.
    # Keep bind target only on the first record in each duplicate group so
    # unique index creation succeeds deterministically.
    execute("""
    WITH ranked AS (
      SELECT
        id,
        ROW_NUMBER() OVER (
          PARTITION BY bind_interface, bind_address, bind_port
          ORDER BY inserted_at ASC, id ASC
        ) AS rn
      FROM endpoints
      WHERE bind_port IS NOT NULL
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

    create unique_index(:endpoints, [:bind_interface, :bind_address, :bind_port],
             where: "bind_port IS NOT NULL"
           )
  end

  def down do
    drop_if_exists index(:endpoints, [:bind_interface, :bind_address, :bind_port])

    alter table(:endpoints) do
      remove :mode
      remove :interface_sys_name
      remove :localaddress
      remove :localport
      remove :address
      remove :port
      remove :host
      remove :latency
      remove :authentication
      remove :passphrase
      remove :pbkeylen
      remove :poll_timeout
      remove :auto_reconnect
      remove :keep_listening
      remove :multicast_iface
      remove :bind_address_option
      remove :bind_interface
      remove :bind_address
      remove :bind_port
    end
  end
end

defmodule HydraSrt.Repo.MigrationsTest do
  use ExUnit.Case, async: false

  defmodule MigrationTestRepo do
    use Ecto.Repo,
      otp_app: :hydra_srt,
      adapter: Ecto.Adapters.SQLite3
  end

  test "sources migration preserves route schema data across up/down/up" do
    migration_version = 20_260_501_120_000
    migrations_path = Application.app_dir(:hydra_srt, "priv/repo/migrations")

    db_path =
      Path.join(
        System.tmp_dir!(),
        "hydra_migration_roundtrip_#{System.unique_integer([:positive])}.db"
      )

    previous_version =
      migrations_path
      |> Path.join("*.exs")
      |> Path.wildcard()
      |> Enum.map(fn path ->
        path |> Path.basename() |> String.split("_", parts: 2) |> hd() |> String.to_integer()
      end)
      |> Enum.filter(&(&1 < migration_version))
      |> Enum.max()

    {:ok, _pid} =
      start_supervised(
        {MigrationTestRepo,
         [
           database: db_path,
           pool: DBConnection.ConnectionPool,
           pool_size: 5,
           journal_mode: :wal
         ]}
      )

    Ecto.Migrator.with_repo(MigrationTestRepo, fn repo ->
      _ = Ecto.Migrator.run(repo, migrations_path, :up, to: previous_version)

      route_id = Ecto.UUID.generate()
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      schema_options =
        Jason.encode!(%{"localaddress" => "127.0.0.1", "localport" => 9100, "mode" => "listener"})

      Ecto.Adapters.SQL.query!(
        repo,
        """
        INSERT INTO routes (
          id, enabled, name, alias, status, schema, schema_options, source,
          started_at, stopped_at, inserted_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, json(?), json(?), ?, ?, ?, ?)
        """,
        [
          route_id,
          1,
          "legacy-route",
          "legacy",
          "started",
          "SRT",
          schema_options,
          "{}",
          nil,
          nil,
          now,
          now
        ]
      )

      _ = Ecto.Migrator.run(repo, migrations_path, :up, to: migration_version)

      %{rows: source_rows} =
        Ecto.Adapters.SQL.query!(
          repo,
          "SELECT route_id, position, schema, json_extract(schema_options, '$.localport') FROM sources WHERE route_id = ?",
          [route_id]
        )

      assert [[^route_id, 0, "SRT", 9100]] = source_rows

      %{rows: route_rows} =
        Ecto.Adapters.SQL.query!(repo, "SELECT active_source_id FROM routes WHERE id = ?", [
          route_id
        ])

      assert [[active_source_id]] = route_rows
      assert is_binary(active_source_id) and active_source_id != ""

      %{rows: route_columns_rows} =
        Ecto.Adapters.SQL.query!(repo, "PRAGMA table_info(routes)", [])

      route_columns_after_up =
        Enum.map(route_columns_rows, fn [_cid, col_name | _] -> col_name end)

      refute "schema" in route_columns_after_up
      refute "schema_options" in route_columns_after_up

      _ = Ecto.Migrator.run(repo, migrations_path, :down, to: previous_version)

      %{rows: down_rows} =
        Ecto.Adapters.SQL.query!(
          repo,
          "SELECT schema, json_extract(schema_options, '$.localport') FROM routes WHERE id = ?",
          [route_id]
        )

      assert [["SRT", 9100]] = down_rows

      _ = Ecto.Migrator.run(repo, migrations_path, :up, to: migration_version)

      %{rows: up_again_rows} =
        Ecto.Adapters.SQL.query!(
          repo,
          "SELECT route_id, position, schema FROM sources WHERE route_id = ?",
          [route_id]
        )

      assert [[^route_id, 0, "SRT"]] = up_again_rows
    end)
  end
end

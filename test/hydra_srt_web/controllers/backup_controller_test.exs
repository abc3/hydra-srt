defmodule HydraSrtWeb.BackupControllerTest do
  use HydraSrtWeb.ConnCase, async: false

  import HydraSrt.DbFixtures

  setup %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> log_in_user()

    {:ok, conn: conn}
  end

  test "exports and imports a versioned route backup", %{conn: conn} do
    route = route_fixture(%{"enabled" => false, "name" => "Contribution"})
    _source = source_fixture(route, %{"name" => "Primary"})

    export_conn = get(conn, ~p"/api/backup/routes")
    backup = json_response(export_conn, 200)

    assert [disposition] = get_resp_header(export_conn, "content-disposition")
    assert disposition =~ ~r/attachment; filename="hydra-srt-routes-\d{10}\.json"/
    assert backup["backup_version"] == "1.0"
    assert [%{"name" => "Contribution"}] = backup["routes"]

    import_conn = post(conn, ~p"/api/backup/routes", backup)

    assert %{
             "message" => "Route backup imported successfully",
             "routes_created" => 1
           } = json_response(import_conn, 200)
  end

  test "rejects an invalid route backup", %{conn: conn} do
    conn =
      post(conn, ~p"/api/backup/routes", %{
        "backup_version" => "1.0",
        "routes" => [%{"name" => "No source", "sources" => []}]
      })

    assert %{"error" => error} = json_response(conn, 422)
    assert error =~ "route_source_required"
  end

  test "downloads a sqlite snapshot and restores it", %{conn: conn} do
    download_conn = get(conn, ~p"/api/backup/full")

    assert Enum.join(get_resp_header(download_conn, "content-type"), ";") =~
             "application/octet-stream"

    assert [disposition] = get_resp_header(download_conn, "content-disposition")
    assert disposition =~ ~r/attachment; filename="hydra-srt-.*\.db"/

    snapshot = response(download_conn, 200)
    assert is_binary(snapshot)
    assert byte_size(snapshot) > 0

    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "hydra_srt_backup_test_#{System.unique_integer([:positive])}.db"
      )

    assert :ok = File.write(tmp_path, snapshot)
    assert :ok = HydraSrt.Backup.validate_db_file(tmp_path)

    restore_conn =
      build_conn()
      |> log_in_user()
      |> put_req_header("content-type", "application/octet-stream")
      |> post(~p"/api/backup/full/restore", snapshot)

    assert %{"message" => "Backup restored successfully"} = json_response(restore_conn, 200)
    assert :ok = HydraSrt.Backup.validate_db_file(HydraSrt.Backup.repo_database_path())
  end

  test "rejects an invalid sqlite backup", %{conn: conn} do
    restore_conn =
      conn
      |> put_req_header("accept", "*/*")
      |> put_req_header("content-type", "application/octet-stream")
      |> post(~p"/api/backup/full/restore", "not a sqlite database")

    assert %{"error" => error} = json_response(restore_conn, 422)
    assert error =~ "Failed to restore backup"
  end

  test "reads backup uploads larger than the default request chunk", %{conn: conn} do
    restore_conn =
      conn
      |> put_req_header("accept", "*/*")
      |> put_req_header("content-type", "application/octet-stream")
      |> post(~p"/api/backup/full/restore", :binary.copy("x", 9_000_000))

    assert %{"error" => _error} = json_response(restore_conn, 422)
  end
end

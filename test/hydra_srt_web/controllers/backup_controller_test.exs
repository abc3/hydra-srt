defmodule HydraSrtWeb.BackupControllerTest do
  use HydraSrtWeb.ConnCase, async: false

  setup %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> log_in_user()

    {:ok, conn: conn}
  end

  test "download backup link returns a sqlite db snapshot and restore accepts it", %{conn: conn} do
    conn = get(conn, ~p"/api/backup/create-backup-download-link")
    assert %{"download_link" => download_link} = json_response(conn, 200)

    public_conn = get(build_conn(), download_link)
    assert Enum.join(get_resp_header(public_conn, "content-type"), ";") =~ "application/x-sqlite3"
    snapshot = response(public_conn, 200)
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
      |> post(~p"/api/restore", snapshot)

    assert %{"message" => "Backup restored successfully"} = json_response(restore_conn, 200)
    assert :ok = HydraSrt.Backup.validate_db_file(HydraSrt.Backup.repo_database_path())
  end
end

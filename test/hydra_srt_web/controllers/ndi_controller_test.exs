defmodule HydraSrtWeb.NdiControllerTest do
  use HydraSrtWeb.ConnCase, async: false

  alias HydraSrt.Ndi.Capabilities

  setup %{conn: conn} do
    previous = Application.get_env(:hydra_srt, :ndi, :__unset__)

    on_exit(fn ->
      case previous do
        :__unset__ -> Application.delete_env(:hydra_srt, :ndi)
        value -> Application.put_env(:hydra_srt, :ndi, value)
      end
    end)

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> log_in_user()

    {:ok, conn: conn}
  end

  test "capabilities requires authentication", %{conn: conn} do
    conn = conn |> delete_req_header("authorization") |> get(~p"/api/system/ndi/capabilities")

    assert json_response(conn, 403)["error"] in ["Unauthorized", "Authorization header missing"]
  end

  test "capabilities returns the documented shape when disabled", %{conn: conn} do
    Application.put_env(:hydra_srt, :ndi, enabled: false)

    conn = get(conn, ~p"/api/system/ndi/capabilities")
    body = json_response(conn, 200)
    data = body["data"]

    refute Map.has_key?(data, "available")
    assert data["feature_enabled"] == false
    assert data["receive"]["reason_codes"] == ["NDI_DISABLED"]
    assert data["discovery"]["mode"] == "mdns"
    assert is_binary(data["checked_at"])
    assert is_binary(data["expires_at"])
    assert is_boolean(data["stale"])
    assert is_boolean(data["check_in_progress"])
  end

  test "sources and refresh return structured NDI_DISABLED when gated", %{conn: conn} do
    Application.put_env(:hydra_srt, :ndi, enabled: false)

    conn = get(conn, ~p"/api/ndi/sources")
    body = json_response(conn, 424)
    assert body["code"] == "NDI_DISABLED"
    assert body["error"]
    assert body["errors"] == %{}

    conn = build_conn() |> put_req_header("accept", "application/json") |> log_in_user()
    conn = post(conn, ~p"/api/ndi/discovery/refresh")
    body = json_response(conn, 424)
    assert body["code"] == "NDI_DISABLED"
  end

  test "probes return structured NDI_DISABLED when gated", %{conn: conn} do
    Application.put_env(:hydra_srt, :ndi, enabled: false)

    conn =
      post(conn, ~p"/api/ndi/probes", %{
        "endpoint" => %{
          "ndi_selection_mode" => "discovery_name",
          "ndi_source_name" => "CAM"
        }
      })

    body = json_response(conn, 424)
    assert body["code"] == "NDI_DISABLED"
  end

  test "refresh returns 202 with generation when enabled", %{conn: conn} do
    Application.put_env(:hydra_srt, :ndi, enabled: true, receive: true, send: false)

    conn = post(conn, ~p"/api/ndi/discovery/refresh")
    body = json_response(conn, 202)
    assert is_binary(body["data"]["generation"])
  end

  test "sources list returns data/meta contract when enabled", %{conn: conn} do
    Application.put_env(:hydra_srt, :ndi, enabled: true, receive: true, send: false)

    # Drive presentation through Capabilities with a fake snapshot via Cache-backed
    # generation path; the live Discovery coordinator may be empty/disabled-capable.
    assert {:ok, presented} =
             Capabilities.list_sources(
               principal: "controller-test",
               snapshot_fun: fn ->
                 %{
                   devices: [
                     %{
                       "display_name" => "Test Cam",
                       "properties" => "url-address=(string)192.0.2.5:5961"
                     }
                   ],
                   stale: false,
                   capability: %{ok: true, reason_code: nil},
                   truncated: false
                 }
               end
             )

    assert presented.meta.result_count == 1
    assert hd(presented.data).name == "Test Cam"

    conn = get(conn, ~p"/api/ndi/sources")
    body = json_response(conn, 200)
    assert is_list(body["data"])
    assert is_map(body["meta"])
    assert Map.has_key?(body["meta"], "generation")
    assert Map.has_key?(body["meta"], "truncated")
    assert Map.has_key?(body["meta"], "duplicate_name_groups")
  end

  test "probe missing body returns structured validation error", %{conn: conn} do
    Application.put_env(:hydra_srt, :ndi, enabled: true, receive: true, send: false)

    conn = post(conn, ~p"/api/ndi/probes", %{})
    body = json_response(conn, 422)
    assert body["code"] == "NDI_CONFIG_INVALID"
    assert body["errors"]["endpoint"]
  end
end

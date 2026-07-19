defmodule HydraSrtWeb.EndpointHealthControllerTest do
  use HydraSrtWeb.ConnCase, async: false

  import HydraSrt.ApiFixtures

  alias HydraSrt.Api
  alias HydraSrt.Ndi.Capabilities
  alias HydraSrt.Repo

  setup %{conn: conn} do
    previous = Application.get_env(:hydra_srt, :ndi, :__unset__)

    on_exit(fn ->
      case previous do
        :__unset__ -> Application.delete_env(:hydra_srt, :ndi)
        value -> Application.put_env(:hydra_srt, :ndi, value)
      end
    end)

    Application.put_env(:hydra_srt, :ndi, enabled: true, receive: true, send: true)

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> log_in_user()

    {:ok, conn: conn}
  end

  test "GET endpoint-health without handler returns derived stopped records", %{conn: conn} do
    route = route_fixture()

    {:ok, source} =
      Api.create_source(route.id, %{
        position: 0,
        schema: "NDI",
        enabled: true,
        name: "ndi-src",
        ndi_selection_mode: "discovery_name",
        ndi_source_name: "CAM (A)"
      })

    conn = get(conn, ~p"/api/routes/#{route.id}/endpoint-health")
    body = json_response(conn, 200)
    data = body["data"]

    assert is_binary(data["generated_at"])
    assert data["config_revision"] == nil
    assert data["process_instance_id"] == nil
    assert data["last_sequence"] == 0
    assert [%{"endpoint_id" => endpoint_id, "state" => "stopped"}] = data["endpoints"]
    assert endpoint_id == source.id
  end

  test "GET endpoint-health requires auth", %{conn: conn} do
    route = route_fixture()

    conn =
      conn
      |> delete_req_header("authorization")
      |> get(~p"/api/routes/#{route.id}/endpoint-health")

    assert json_response(conn, 403)["error"] in ["Unauthorized", "Authorization header missing"]
  end

  test "create NDI source with selection_token persists snapshot and never stores the token", %{
    conn: conn
  } do
    route = route_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expires = DateTime.add(now, 120, :second)

    # Principal must match the Bearer hash used by SourceController.auth_principal/1.
    ["Bearer " <> raw] = get_req_header(conn, "authorization")
    principal = HydraSrt.Auth.hash_token(raw)

    token =
      Capabilities.mint_selection_token(
        principal,
        "gen-ctrl",
        %{name: "CTRL (Cam)", url_address: "192.0.2.77:5961"},
        expires
      )

    conn =
      post(conn, ~p"/api/routes/#{route.id}/sources",
        source: %{
          "position" => 0,
          "schema" => "NDI",
          "name" => "from-token",
          "ndi_selection_mode" => "discovery_name",
          "ndi_source_name" => "CTRL (Cam)",
          "selection_token" => token
        }
      )

    assert %{"id" => source_id} = json_response(conn, 201)["data"]
    data = json_response(conn, 201)["data"]

    assert data["ndi_source_name"] == "CTRL (Cam)"
    assert data["ndi_observed_address_snapshot"] == "192.0.2.77:5961"
    assert data["ndi_selection_observed_at"]
    refute Map.has_key?(data, "selection_token")

    reloaded = Repo.get!(HydraSrt.Api.Endpoint, source_id)
    assert reloaded.ndi_source_name == "CTRL (Cam)"
    assert reloaded.ndi_observed_address_snapshot == "192.0.2.77:5961"
    assert reloaded.ndi_selection_observed_at
  end

  test "create NDI source with expired selection_token returns structured error", %{conn: conn} do
    route = route_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expires = DateTime.add(now, -5, :second)

    ["Bearer " <> raw] = get_req_header(conn, "authorization")
    principal = HydraSrt.Auth.hash_token(raw)

    token =
      Capabilities.mint_selection_token(
        principal,
        "gen-expired",
        %{name: "OLD", url_address: "192.0.2.1:5961"},
        expires
      )

    conn =
      post(conn, ~p"/api/routes/#{route.id}/sources",
        source: %{
          "position" => 0,
          "schema" => "NDI",
          "name" => "bad-token",
          "ndi_selection_mode" => "discovery_name",
          "selection_token" => token
        }
      )

    body = json_response(conn, 422)
    assert body["code"] == "NDI_DISCOVERY_UNAVAILABLE"
    assert body["error"]
    assert body["errors"]["selection_token"]
  end

  test "create direct_address NDI source persists observed_name snapshot", %{conn: conn} do
    route = route_fixture()

    conn =
      post(conn, ~p"/api/routes/#{route.id}/sources",
        source: %{
          "position" => 0,
          "schema" => "NDI",
          "name" => "direct",
          "ndi_selection_mode" => "direct_address",
          "ndi_source_address" => "192.0.2.88:5961",
          "ndi_observed_name_snapshot" => "LAN (Direct)"
        }
      )

    data = json_response(conn, 201)["data"]
    assert data["ndi_source_address"] == "192.0.2.88:5961"
    assert data["ndi_observed_name_snapshot"] == "LAN (Direct)"
    assert data["ndi_selection_observed_at"]
    assert data["ndi_source_name"] == nil
  end
end

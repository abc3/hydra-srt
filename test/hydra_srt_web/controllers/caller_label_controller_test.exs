defmodule HydraSrtWeb.CallerLabelControllerTest do
  use HydraSrtWeb.ConnCase, async: false

  setup %{conn: conn} do
    {:ok, conn: conn |> put_req_header("accept", "application/json") |> log_in_user()}
  end

  test "caller label CRUD endpoints", %{conn: conn} do
    conn = post(conn, ~p"/api/caller-labels", %{"address" => "203.0.113.5", "label" => "Studio"})

    assert %{"id" => id, "address" => "203.0.113.5", "label" => "Studio", "note" => nil} =
             json_response(conn, 201)["data"]

    conn = get(conn, ~p"/api/caller-labels")
    assert [%{"id" => ^id}] = json_response(conn, 200)["data"]

    conn =
      patch(conn, ~p"/api/caller-labels/#{id}", %{
        "label" => "Control room",
        "note" => "Known caller"
      })

    assert %{"label" => "Control room", "note" => "Known caller"} =
             json_response(conn, 200)["data"]

    conn = delete(conn, ~p"/api/caller-labels/#{id}")
    assert response(conn, 204)
  end

  test "caller label create validates address", %{conn: conn} do
    conn = post(conn, ~p"/api/caller-labels", %{"address" => "bad", "label" => "Studio"})
    assert json_response(conn, 422)["errors"]["address"]
  end
end

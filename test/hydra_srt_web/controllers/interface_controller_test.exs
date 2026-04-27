defmodule HydraSrtWeb.InterfaceControllerTest do
  use HydraSrtWeb.ConnCase

  import HydraSrt.ApiFixtures

  @create_attrs %{
    "name" => "ISP-1",
    "ip" => "172.20.20.12/24",
    "sys_name" => "eno1",
    "enabled" => true
  }
  @update_attrs %{
    "name" => "MCAST-OUT",
    "ip" => "192.168.221.15/24",
    "sys_name" => "eno2",
    "enabled" => false
  }
  @invalid_attrs %{"name" => nil, "ip" => nil, "sys_name" => nil, "enabled" => nil}

  setup %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> log_in_user()

    {:ok, conn: conn}
  end

  describe "index" do
    test "lists all interfaces", %{conn: conn} do
      conn = get(conn, ~p"/api/interfaces")
      assert json_response(conn, 200)["data"] == []
    end

    test "rejects request without bearer token", %{conn: conn} do
      conn = delete_req_header(conn, "authorization")
      conn = get(conn, ~p"/api/interfaces")
      assert json_response(conn, 403)["error"] in ["Unauthorized", "Authorization header missing"]
    end
  end

  describe "create interface" do
    test "renders interface when data is valid", %{conn: conn} do
      conn = post(conn, ~p"/api/interfaces", interface: @create_attrs)
      assert %{"id" => id} = json_response(conn, 201)["data"]

      conn = get(conn, ~p"/api/interfaces/#{id}")

      assert %{
               "id" => ^id,
               "ip" => "172.20.20.12/24",
               "name" => "ISP-1",
               "sys_name" => "eno1",
               "enabled" => true
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = post(conn, ~p"/api/interfaces", interface: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end

    test "allows missing name", %{conn: conn} do
      attrs = %{
        "name" => nil,
        "ip" => "10.10.10.10/24",
        "sys_name" => "eno9",
        "enabled" => true
      }

      conn = post(conn, ~p"/api/interfaces", interface: attrs)
      assert %{"id" => id} = json_response(conn, 201)["data"]

      conn = get(conn, ~p"/api/interfaces/#{id}")
      assert json_response(conn, 200)["data"]["name"] == nil
    end
  end

  describe "update interface" do
    setup [:create_interface]

    test "renders interface when data is valid", %{conn: conn, interface: %{"id" => id}} do
      conn = put(conn, ~p"/api/interfaces/#{id}", interface: @update_attrs)
      assert %{"id" => ^id} = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/api/interfaces/#{id}")

      assert %{
               "id" => ^id,
               "ip" => "192.168.221.15/24",
               "name" => "MCAST-OUT",
               "sys_name" => "eno2",
               "enabled" => false
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn, interface: %{"id" => id}} do
      conn = put(conn, ~p"/api/interfaces/#{id}", interface: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "delete interface" do
    setup [:create_interface]

    test "deletes chosen interface", %{conn: conn, interface: %{"id" => id}} do
      conn = delete(conn, ~p"/api/interfaces/#{id}")
      assert response(conn, 204)

      conn = get(conn, ~p"/api/interfaces/#{id}")
      assert json_response(conn, 404)
    end
  end

  describe "system interfaces" do
    test "returns parsed interfaces from ifconfig", %{conn: conn} do
      conn = get(conn, ~p"/api/interfaces/system")
      payload = json_response(conn, 200)["data"]

      assert is_list(payload)

      assert Enum.all?(payload, fn item ->
               is_map(item) and is_binary(item["sys_name"]) and is_binary(item["ip"]) and
                 is_boolean(item["multicast_supported"]) and is_binary(item["raw_description"])
             end)
    end

    test "returns raw ifconfig output", %{conn: conn} do
      conn = get(conn, ~p"/api/interfaces/system/raw")
      payload = json_response(conn, 200)["data"]

      assert is_map(payload)
      assert is_binary(payload["raw"])
      assert String.length(payload["raw"]) > 0
    end
  end

  def create_interface(_) do
    interface = interface_fixture()
    %{interface: %{"id" => interface.id}}
  end
end

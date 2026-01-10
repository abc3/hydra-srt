defmodule HydraSrtWeb.LiveChannelTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  @endpoint HydraSrtWeb.Endpoint

  setup do
    # Channel auth depends on Cachex sessions.
    case Process.whereis(HydraSrt.Cache) do
      pid when is_pid(pid) ->
        :ok

      _ ->
        {:ok, _pid} = Cachex.start_link(name: HydraSrt.Cache)
        :ok
    end

    token = "test_token_#{System.unique_integer([:positive])}"
    Cachex.put(HydraSrt.Cache, "auth_session:#{token}", "admin", ttl: :timer.minutes(5))

    {:ok, socket} = connect(HydraSrtWeb.UserSocket, %{"token" => token})

    {:ok, socket: socket, route_id: "route_#{System.unique_integer([:positive])}"}
  end

  test "pushes PubSub stats to websocket clients", %{socket: socket, route_id: route_id} do
    {:ok, _reply, socket} =
      subscribe_and_join(socket, HydraSrtWeb.LiveChannel, "live:#{route_id}")

    payload = %{
      "source" => %{"bytes_in_per_sec" => 123},
      "destinations" => [%{"id" => "d1", "schema" => "UDP", "bytes_out_per_sec" => 10}]
    }

    Phoenix.PubSub.broadcast(HydraSrt.PubSub, "stats:#{route_id}", {:stats, payload})

    assert_push("stats", ^payload)
    assert socket.assigns.route_id == route_id
  end
end

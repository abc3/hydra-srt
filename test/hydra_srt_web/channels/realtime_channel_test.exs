defmodule HydraSrtWeb.RealtimeChannelTest do
  use HydraSrt.DataCase

  import Phoenix.ChannelTest

  @endpoint HydraSrtWeb.Endpoint

  setup do
    token = "test_token_#{System.unique_integer([:positive])}"
    {:ok, _session} = HydraSrt.Auth.create_session(token, "admin")
    {:ok, token: token}
  end

  test "rejects socket connections without a valid token" do
    assert :error = connect(HydraSrtWeb.UserSocket, %{"token" => "missing-token"})
    assert :error = connect(HydraSrtWeb.UserSocket, %{})
  end

  test "subscribes to stats topics and pushes realtime stats", %{token: token} do
    assert {:ok, socket} = connect(HydraSrtWeb.UserSocket, %{"token" => token})
    assert {:ok, _, socket} = subscribe_and_join(socket, HydraSrtWeb.RealtimeChannel, "realtime")

    ref = push(socket, "stats:subscribe", %{})

    assert_reply ref, :ok

    Phoenix.PubSub.broadcast(
      HydraSrt.PubSub,
      "stats",
      {:stats,
       %{
         route_id: "route-1",
         direction: "in",
         metric: "bytes_per_sec",
         value: 12_345
       }}
    )

    assert_push "stats", %{
      route_id: "route-1",
      direction: "in",
      metric: "bytes_per_sec",
      value: 12_345
    }
  end
end

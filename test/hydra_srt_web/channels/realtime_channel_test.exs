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

  test "subscribes to system pipelines and pushes snapshot", %{token: token} do
    assert {:ok, socket} = connect(HydraSrtWeb.UserSocket, %{"token" => token})
    assert {:ok, _, socket} = subscribe_and_join(socket, HydraSrtWeb.RealtimeChannel, "realtime")

    ref = push(socket, "system_pipelines:subscribe", %{})

    assert_push "system_pipelines", %{pipelines: pipelines, routes: routes}
    assert is_list(pipelines)
    assert is_list(routes)
    assert_reply ref, :ok

    unsub_ref = push(socket, "system_pipelines:unsubscribe", %{})
    assert_reply unsub_ref, :ok
  end

  test "subscribes to item topic and pushes item status event", %{token: token} do
    assert {:ok, socket} = connect(HydraSrtWeb.UserSocket, %{"token" => token})
    assert {:ok, _, socket} = subscribe_and_join(socket, HydraSrtWeb.RealtimeChannel, "realtime")

    ref = push(socket, "item:subscribe", %{"item_id" => "dest-1"})
    assert_reply ref, :ok

    Phoenix.PubSub.broadcast(
      HydraSrt.PubSub,
      "item:dest-1",
      {:item_status, %{item_id: "dest-1", status: "processing"}}
    )

    assert_push "item_status", %{item_id: "dest-1", status: "processing"}
  end

  test "subscribes to item topic and pushes item source event", %{token: token} do
    assert {:ok, socket} = connect(HydraSrtWeb.UserSocket, %{"token" => token})
    assert {:ok, _, socket} = subscribe_and_join(socket, HydraSrtWeb.RealtimeChannel, "realtime")

    ref = push(socket, "item:subscribe", %{"item_id" => "route-1"})
    assert_reply ref, :ok

    Phoenix.PubSub.broadcast(
      HydraSrt.PubSub,
      "item:route-1",
      {:item_source,
       %{
         item_id: "route-1",
         active_source_id: "source-2",
         last_switch_reason: "manual",
         last_switch_at: "2026-05-01T12:30:00Z"
       }}
    )

    assert_push "item_source", %{
      item_id: "route-1",
      active_source_id: "source-2",
      last_switch_reason: "manual",
      last_switch_at: "2026-05-01T12:30:00Z"
    }
  end

  test "item topic subscribe is idempotent and unsubscribe stops pushes", %{token: token} do
    assert {:ok, socket} = connect(HydraSrtWeb.UserSocket, %{"token" => token})
    assert {:ok, _, socket} = subscribe_and_join(socket, HydraSrtWeb.RealtimeChannel, "realtime")

    first_ref = push(socket, "item:subscribe", %{"item_id" => "route-1"})
    assert_reply first_ref, :ok

    second_ref = push(socket, "item:subscribe", %{"item_id" => "route-1"})
    assert_reply second_ref, :ok

    unsub_ref = push(socket, "item:unsubscribe", %{"item_id" => "route-1"})
    assert_reply unsub_ref, :ok

    Phoenix.PubSub.broadcast(
      HydraSrt.PubSub,
      "item:route-1",
      {:item_status, %{item_id: "route-1", status: "stopped"}}
    )

    refute_push "item_status", _, 150
  end

  test "subscribes to events topic and pushes event payload", %{token: token} do
    assert {:ok, socket} = connect(HydraSrtWeb.UserSocket, %{"token" => token})
    assert {:ok, _, socket} = subscribe_and_join(socket, HydraSrtWeb.RealtimeChannel, "realtime")

    ref = push(socket, "events:subscribe", %{"route_id" => "route-1"})
    assert_reply ref, :ok

    Phoenix.PubSub.broadcast(
      HydraSrt.PubSub,
      "events:route-1",
      {:event,
       %{
         "route_id" => "route-1",
         "event_type" => "source_switch",
         "reason" => "manual"
       }}
    )

    assert_push "event", %{
      "route_id" => "route-1",
      "event_type" => "source_switch",
      "reason" => "manual"
    }
  end
end

defmodule HydraSrt.Youtube.RefreshSchedulerTest do
  use ExUnit.Case, async: false

  alias HydraSrt.Youtube.RefreshScheduler

  @url "https://www.youtube.com/watch?v=fO9e9jnhYK8"

  setup do
    previous = Application.get_env(:hydra_srt, :youtube, :__unset__)
    name = String.to_atom("youtube_refresh_scheduler_test_#{System.unique_integer()}")

    Application.put_env(:hydra_srt, :youtube, enabled: true)
    Phoenix.PubSub.subscribe(HydraSrt.PubSub, "youtube:refresh")

    on_exit(fn ->
      case previous do
        :__unset__ -> Application.delete_env(:hydra_srt, :youtube)
        value -> Application.put_env(:hydra_srt, :youtube, value)
      end
    end)

    %{name: name}
  end

  test "schedules a canonical URL and broadcasts when its timer expires", %{name: name} do
    {:ok, pid} = RefreshScheduler.start_link(name: name)

    assert :ok =
             RefreshScheduler.schedule("youtu.be/fO9e9jnhYK8?si=ignored",
               delay_ms: 5,
               server: name
             )

    assert_receive {:youtube_refresh, @url}, 500
    refute :sys.get_state(pid).timers |> Map.has_key?(@url)

    GenServer.stop(pid)
  end

  test "rescheduling a URL replaces the previous timer", %{name: name} do
    {:ok, pid} = RefreshScheduler.start_link(name: name)

    assert :ok = RefreshScheduler.schedule(@url, delay_ms: 250, server: name)
    assert :ok = RefreshScheduler.schedule(@url, delay_ms: 5, server: name)

    assert_receive {:youtube_refresh, @url}, 500
    refute_receive {:youtube_refresh, @url}, 350

    GenServer.stop(pid)
  end

  test "uses the minimum delay for an expired URI and the calculated delay for a distant expiry" do
    now = RefreshScheduler.now_seconds()

    assert RefreshScheduler.calculated_delay(expires_at: now - 1, jitter_ms: 0) ==
             :timer.seconds(30)

    assert RefreshScheduler.calculated_delay(expires_at: now + 3_600, jitter_ms: 0) in 2_999_000..3_000_000
  end

  test "cancelling a URL prevents its refresh notification", %{name: name} do
    {:ok, pid} = RefreshScheduler.start_link(name: name)

    assert :ok = RefreshScheduler.schedule(@url, delay_ms: 50, server: name)
    assert :ok = RefreshScheduler.cancel(@url, name)

    refute_receive {:youtube_refresh, @url}, 150
    assert :sys.get_state(pid).timers == %{}

    GenServer.stop(pid)
  end

  test "does not schedule while the YouTube feature is disabled", %{name: name} do
    Application.put_env(:hydra_srt, :youtube, enabled: false)
    {:ok, pid} = RefreshScheduler.start_link(name: name)

    assert :ok = RefreshScheduler.schedule(@url, delay_ms: 1, server: name)
    assert :sys.get_state(pid).timers == %{}
    refute_receive {:youtube_refresh, @url}, 50

    GenServer.stop(pid)
  end

  test "ignores unknown messages and remains available for later schedules", %{name: name} do
    {:ok, pid} = RefreshScheduler.start_link(name: name)
    send(pid, :unexpected_message)

    assert Process.alive?(pid)
    assert :ok = RefreshScheduler.schedule(@url, delay_ms: 5, server: name)
    assert_receive {:youtube_refresh, @url}, 500

    GenServer.stop(pid)
  end

  test "schedule is a no-op when its server is not running" do
    Application.put_env(:hydra_srt, :youtube, enabled: true)

    assert :ok = RefreshScheduler.schedule(@url, delay_ms: 1, server: :missing_youtube_scheduler)
    refute_receive {:youtube_refresh, @url}, 50
  end
end

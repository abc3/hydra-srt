defmodule HydraSrt.Ndi.ProbeTest do
  use ExUnit.Case, async: false

  alias HydraSrt.Ndi.Probe

  setup do
    previous = Application.get_env(:hydra_srt, :ndi, :__unset__)
    Application.put_env(:hydra_srt, :ndi, enabled: true, receive: true, send: false)

    on_exit(fn ->
      case previous do
        :__unset__ -> Application.delete_env(:hydra_srt, :ndi)
        value -> Application.put_env(:hydra_srt, :ndi, value)
      end
    end)

    :ok
  end

  test "disabled receive never launches a port" do
    Application.put_env(:hydra_srt, :ndi, enabled: false)

    launcher = fn _path, _args ->
      flunk("must not launch when disabled")
    end

    assert {:error, "NDI_DISABLED", _} =
             Probe.run(
               %{
                 "id" => Ecto.UUID.generate(),
                 "kind" => "ndi",
                 "ndi" => %{
                   "source_name" => "CAM",
                   "receiver_name" => "Hydra probe",
                   "bandwidth" => "highest",
                   "color_format" => "uyvy-bgra",
                   "media_policy" => "video_only",
                   "connect_timeout_ms" => 1000,
                   "receive_timeout_ms" => 1000,
                   "track_discovery_timeout_ms" => 1000,
                   "max_queue_length" => 4
                 }
               },
               port_launcher: launcher
             )
  end

  test "injected port collects probe_result JSONL" do
    test_pid = self()
    probe_id = Ecto.UUID.generate()

    launcher = fn path, args ->
      assert String.ends_with?(path, "hydra_srt_pipeline")
      assert args == ["ndi-probe", "--probe-instance-id", probe_id]
      ref = make_ref()
      send(test_pid, {:launched, self(), ref})
      ref
    end

    commander = fn port, payload ->
      send(test_pid, {:stdin, port, payload})
      :ok
    end

    closer = fn port ->
      send(test_pid, {:closed, port})
      :ok
    end

    task =
      Task.async(fn ->
        Probe.run(
          %{
            "id" => "src-1",
            "kind" => "ndi",
            "ndi" => %{
              "source_name" => "CAM",
              "receiver_name" => "Hydra probe",
              "bandwidth" => "highest",
              "color_format" => "uyvy-bgra",
              "media_policy" => "video_only",
              "connect_timeout_ms" => 1000,
              "receive_timeout_ms" => 1000,
              "track_discovery_timeout_ms" => 1000,
              "max_queue_length" => 4
            }
          },
          port_launcher: launcher,
          port_commander: commander,
          port_closer: closer,
          probe_instance_id: probe_id,
          timeout_ms: 2_000
        )
      end)

    assert_receive {:launched, probe_pid, port}, 500
    assert_receive {:stdin, ^port, stdin}, 500
    assert String.contains?(stdin, "\"kind\":\"ndi\"")

    line =
      Jason.encode!(%{
        "event" => "probe_result",
        "probe_instance_id" => probe_id,
        "ok" => true,
        "reason_code" => nil,
        "video_caps" => "video/x-raw, width=1920",
        "audio_caps" => nil,
        "elapsed_ms" => 42
      })

    send(probe_pid, {port, {:data, line <> "\n"}})
    send(probe_pid, {port, {:exit_status, 0}})

    assert {:ok, result} = Task.await(task)
    assert result.ok == true
    assert result.code == nil
    assert result.video_caps == "video/x-raw, width=1920"
    assert result.elapsed_ms == 42
    assert_receive {:closed, ^port}, 500
  end

  test "timeout returns stable helper unhealthy code" do
    test_pid = self()

    launcher = fn _path, _args ->
      ref = make_ref()
      send(test_pid, {:launched, self(), ref})
      ref
    end

    task =
      Task.async(fn ->
        Probe.run(
          %{
            "id" => "src-1",
            "kind" => "ndi",
            "ndi" => %{
              "source_name" => "CAM",
              "receiver_name" => "Hydra probe",
              "bandwidth" => "highest",
              "color_format" => "uyvy-bgra",
              "media_policy" => "video_only",
              "connect_timeout_ms" => 1000,
              "receive_timeout_ms" => 1000,
              "track_discovery_timeout_ms" => 1000,
              "max_queue_length" => 4
            }
          },
          port_launcher: launcher,
          port_commander: fn _port, _payload -> :ok end,
          port_closer: fn _port -> :ok end,
          timeout_ms: 50
        )
      end)

    assert_receive {:launched, _probe_pid, _port}, 500
    assert {:error, "NDI_HELPER_UNHEALTHY", message} = Task.await(task)
    assert message =~ "timed out"
  end

  test "maps DB-shaped NDI source via RouteHandler" do
    test_pid = self()

    launcher = fn _path, _args ->
      ref = make_ref()
      send(test_pid, {:launched, self(), ref})
      ref
    end

    task =
      Task.async(fn ->
        Probe.run(
          %{
            "id" => "src-1",
            "schema" => "NDI",
            "ndi_selection_mode" => "discovery_name",
            "ndi_source_name" => "MACHINE (CHANNEL)",
            "ndi_media_policy" => "video_only"
          },
          route: %{"id" => "route-1", "name" => "Demo"},
          port_launcher: launcher,
          port_commander: fn _port, payload ->
            send(test_pid, {:stdin, payload})
            :ok
          end,
          port_closer: fn _ -> :ok end,
          timeout_ms: 500
        )
      end)

    assert_receive {:launched, probe_pid, port}, 500
    assert_receive {:stdin, stdin}, 500
    assert String.contains?(stdin, "MACHINE (CHANNEL)")

    line =
      Jason.encode!(%{
        "event" => "probe_result",
        "ok" => false,
        "reason_code" => "NDI_PLUGIN_MISSING",
        "elapsed_ms" => 1
      })

    send(probe_pid, {port, {:data, line <> "\n"}})

    assert {:ok, result} = Task.await(task)
    assert result.ok == false
    assert result.code == "NDI_PLUGIN_MISSING"
  end
end

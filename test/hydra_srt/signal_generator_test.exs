defmodule HydraSrt.SignalGeneratorTest do
  use ExUnit.Case, async: false

  alias HydraSrt.SignalGenerator

  setup do
    on_exit(fn ->
      _ = SignalGenerator.stop_generation("srt")
    end)

    :ok
  end

  test "restarts ffmpeg two seconds after unexpected exit" do
    tmp_dir = System.tmp_dir!()
    unique = System.unique_integer([:positive])
    script = Path.join(tmp_dir, "hydra_signal_generator_test_#{unique}.sh")
    marker = Path.join(tmp_dir, "hydra_signal_generator_test_#{unique}.marker")

    File.write!(
      script,
      """
      #!/bin/sh
      MARKER='#{marker}'
      if [ ! -f "$MARKER" ]; then
        touch "$MARKER"
        exit 1
      fi
      exec tail -f /dev/null
      """
    )

    File.chmod!(script, 0o755)

    on_exit(fn ->
      File.rm(script)
      _ = File.rm(marker)
    end)

    :sys.replace_state(SignalGenerator, fn state ->
      %{state | ffmpeg_path: script, configs: put_in(state.configs, ["srt", :port], 42_099)}
    end)

    assert {:ok, %{"running" => true}} = SignalGenerator.start_generation("srt")

    # First launch exits immediately; after @restart_delay_ms the generator relaunches.
    Process.sleep(SignalGenerator.restart_delay_ms() + 200)

    assert_eventually(fn ->
      status = SignalGenerator.status("srt")
      status["running"] and status["running_transport"] == "srt"
    end)
  end

  test "does not restart after explicit stop" do
    script =
      Path.join(
        System.tmp_dir!(),
        "hydra_signal_generator_test_#{System.unique_integer([:positive])}.sh"
      )

    File.write!(script, "#!/bin/sh\nexec tail -f /dev/null\n")
    File.chmod!(script, 0o755)

    on_exit(fn -> File.rm(script) end)

    :sys.replace_state(SignalGenerator, fn state ->
      %{state | ffmpeg_path: script, configs: put_in(state.configs, ["srt", :port], 42_098)}
    end)

    assert {:ok, %{"running" => true}} = SignalGenerator.start_generation("srt")
    assert {:ok, %{"running" => false}} = SignalGenerator.stop_generation("srt")

    Process.sleep(SignalGenerator.restart_delay_ms() + 200)

    assert %{"running" => false, "running_transport" => nil} = SignalGenerator.status("srt")
  end

  defp assert_eventually(fun, attempts \\ 20) do
    if fun.() do
      :ok
    else
      if attempts > 0 do
        Process.sleep(250)
        assert_eventually(fun, attempts - 1)
      else
        flunk("condition not met in time")
      end
    end
  end
end

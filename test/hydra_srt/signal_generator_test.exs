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
    script =
      Path.join(
        System.tmp_dir!(),
        "hydra_signal_generator_test_#{System.unique_integer([:positive])}.sh"
      )

    File.write!(script, "#!/bin/sh\nexit 1\n")
    File.chmod!(script, 0o755)

    on_exit(fn -> File.rm(script) end)

    :sys.replace_state(SignalGenerator, fn state ->
      %{state | ffmpeg_path: script, configs: put_in(state.configs, ["srt", :port], 42_099)}
    end)

    assert {:ok, %{"running" => true}} = SignalGenerator.start_generation("srt")

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

    File.write!(script, "#!/bin/sh\nsleep 60\n")
    File.chmod!(script, 0o755)

    on_exit(fn -> File.rm(script) end)

    :sys.replace_state(SignalGenerator, fn state ->
      %{state | ffmpeg_path: script, configs: put_in(state.configs, ["srt", :port], 42_098)}
    end)

    assert {:ok, %{"running" => true}} = SignalGenerator.start_generation("srt")
    assert {:ok, %{"running" => false}} = SignalGenerator.stop_generation("srt")

    Process.sleep(2_500)

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

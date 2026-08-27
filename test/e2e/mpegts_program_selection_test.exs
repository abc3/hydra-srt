defmodule HydraSrt.E2E.MpegTsProgramSelectionTest do
  use ExUnit.Case, async: false

  alias HydraSrt.SourceProbe
  alias HydraSrt.TestSupport.E2EHelpers

  @moduletag :e2e

  setup_all do
    E2EHelpers.ensure_e2e_prereqs!()
    {:ok, base_url: E2EHelpers.base_url()}
  end

  test "UDP source selection forwards only the selected MPEG-TS program", %{base_url: base_url} do
    assert_programs_forwarded(base_url, 12, [12])
  end

  test "UDP source without a program number forwards the whole multiplex", %{
    base_url: base_url
  } do
    assert_programs_forwarded(base_url, nil, [11, 12])
  end

  defp assert_programs_forwarded(base_url, program_number, expected_programs) do
    token = E2EHelpers.api_login!(base_url, "admin", "password123")
    source_port = E2EHelpers.udp_free_port!()
    counter_port = E2EHelpers.udp_free_port!()
    destination_port = E2EHelpers.udp_free_port!()
    capture_file = E2EHelpers.tmp_file!("mpegts_program_selection", "ts")
    udp_counter = E2EHelpers.start_udp_counter!(counter_port)
    on_exit(fn -> E2EHelpers.stop_udp_counter!(udp_counter) end)

    route_id =
      E2EHelpers.api_create_route!(base_url, token, %{
        "name" => "e2e_mpegts_program_selection_#{System.unique_integer([:positive])}"
      })

    on_exit(fn ->
      E2EHelpers.api_stop_route(base_url, token, route_id)
      E2EHelpers.api_delete_route(base_url, token, route_id)
      File.rm(capture_file)
    end)

    source_attrs = %{
      "position" => 0,
      "enabled" => true,
      "name" => "mpts-source",
      "schema" => "UDP",
      "host" => "127.0.0.1",
      "port" => source_port
    }

    source_attrs =
      if is_integer(program_number),
        do: Map.put(source_attrs, "program_number", program_number),
        else: source_attrs

    _source_id = E2EHelpers.api_create_source!(base_url, token, route_id, source_attrs)

    :ok =
      E2EHelpers.api_create_destination!(base_url, token, route_id, %{
        "schema" => "UDP",
        "name" => "mpts-counter",
        "host" => "127.0.0.1",
        "port" => counter_port
      })

    :ok =
      E2EHelpers.api_create_destination!(base_url, token, route_id, %{
        "schema" => "UDP",
        "name" => "mpts-capture",
        "host" => "127.0.0.1",
        "port" => destination_port
      })

    capture = start_udp_capture!(capture_file, destination_port)
    on_exit(fn -> stop_udp_capture!(capture) end)

    # The route only reaches processing once packets are actually arriving, so the sender has to
    # be running before we wait for it.
    sender = start_mpts_sender!(source_port)
    on_exit(fn -> E2EHelpers.kill_port(sender) end)

    :ok = E2EHelpers.api_start_route!(base_url, token, route_id)

    E2EHelpers.wait_for_route_processing!(base_url, token, route_id,
      timeout_ms: 25_000,
      expected_destination_count: 2
    )

    E2EHelpers.wait_until(
      fn ->
        case File.stat(capture_file) do
          {:ok, %{size: size}} -> size >= 188 * 100
          _ -> false
        end
      end,
      15_000,
      100
    )

    assert {:ok, %{bytes: bytes}} = E2EHelpers.await_udp_bytes(udp_counter, 188 * 100, 15_000)
    assert bytes >= 188 * 100

    E2EHelpers.kill_port(sender)
    # Close the capture before probing it: ffprobe reading a file that is still being appended
    # to sees a partial stream and reports whatever half-written tables it lands on.
    stop_udp_capture!(capture)

    {:ok, raw} = SourceProbe.run_ffprobe(:ffprobe, capture_file, 15_000)
    {:ok, decoded} = SourceProbe.decode_output(raw)
    programs = SourceProbe.normalize_programs(decoded["programs"])

    assert Enum.map(programs, & &1["program_number"]) == expected_programs,
           "expected programs #{inspect(expected_programs)}, got #{inspect(programs)}"

    assert Enum.all?(programs, &is_list(&1["streams"]))
  end

  # ffmpeg rebuilds the PAT whenever it muxes, so streaming a prepared file with -c copy would
  # flatten the multiplex into a single program. Generate both programs straight onto the wire.
  defp start_mpts_sender!(source_port) do
    E2EHelpers.start_port_logged!(
      "ffmpeg",
      [
        "-hide_banner",
        "-loglevel",
        "error",
        "-re",
        "-f",
        "lavfi",
        "-i",
        "testsrc2=size=320x180:rate=15:duration=40",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=440:duration=40",
        "-f",
        "lavfi",
        "-i",
        "testsrc2=size=320x180:rate=15:duration=40",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=880:duration=40",
        "-c:v",
        "libx264",
        "-preset",
        "ultrafast",
        "-tune",
        "zerolatency",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        "-map",
        "0:v",
        "-map",
        "1:a",
        "-map",
        "2:v",
        "-map",
        "3:a",
        "-program",
        "program_num=11:st=0:st=1",
        "-program",
        "program_num=12:st=2:st=3",
        "-f",
        "mpegts",
        "udp://127.0.0.1:#{source_port}"
      ],
      "ffmpeg_mpts_sender"
    )
  end

  defp start_udp_capture!(capture_file, destination_port) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_udp.open(destination_port, [:binary, active: true])
        {:ok, file} = File.open(capture_file, [:write, :binary])
        send(parent, {:udp_capture_ready, self()})
        udp_capture_loop(socket, file, parent)
      end)

    receive do
      {:udp_capture_ready, ^pid} -> %{pid: pid}
    after
      2_000 -> raise "timed out opening UDP capture socket"
    end
  end

  defp udp_capture_loop(socket, file, parent) do
    receive do
      {:udp, ^socket, _ip, _port, data} ->
        :ok = IO.binwrite(file, data)
        udp_capture_loop(socket, file, parent)

      :stop ->
        :gen_udp.close(socket)
        File.close(file)
        send(parent, :udp_capture_stopped)
    end
  end

  defp stop_udp_capture!(%{pid: pid}) do
    if Process.alive?(pid) do
      send(pid, :stop)

      receive do
        :udp_capture_stopped -> :ok
      after
        2_000 -> :ok
      end
    end
  end
end

defmodule HydraSrt.E2E.SrtFailoverTest do
  use ExUnit.Case, async: false

  alias HydraSrt.TestSupport.E2EHelpers

  @moduletag :e2e

  setup_all do
    E2EHelpers.ensure_e2e_prereqs!()
    {:ok, base_url: E2EHelpers.base_url()}
  end

  test "manual source switch to backup keeps pipeline working and persists source_switch event",
       %{
         base_url: base_url
       } do
    token = E2EHelpers.api_login!(base_url, "admin", "password123")

    primary_source_port = E2EHelpers.tcp_free_port!()
    backup_source_port = E2EHelpers.tcp_free_port!()
    udp_dest_port = E2EHelpers.udp_free_port!()

    udp_counter = E2EHelpers.start_udp_counter!(udp_dest_port)

    on_exit(fn ->
      E2EHelpers.stop_udp_counter!(udp_counter)
    end)

    route_id =
      E2EHelpers.api_create_route!(base_url, token, %{
        "name" => "e2e_srt_failover_manual_switch",
        "backup_config" => %{
          "mode" => "passive",
          "switch_after_ms" => 1000,
          "cooldown_ms" => 2000
        }
      })

    on_exit(fn ->
      E2EHelpers.api_stop_route(base_url, token, route_id)
      E2EHelpers.api_delete_route(base_url, token, route_id)
    end)

    primary_source_id =
      E2EHelpers.api_create_source!(base_url, token, route_id, %{
        "position" => 0,
        "enabled" => true,
        "name" => "primary-e2e",
        "schema" => "SRT",
        "schema_options" => %{
          "localaddress" => "127.0.0.1",
          "localport" => primary_source_port,
          "mode" => "listener"
        }
      })

    backup_source_id =
      E2EHelpers.api_create_source!(base_url, token, route_id, %{
        "position" => 1,
        "enabled" => true,
        "name" => "backup-e2e",
        "schema" => "SRT",
        "schema_options" => %{
          "localaddress" => "127.0.0.1",
          "localport" => backup_source_port,
          "mode" => "listener"
        }
      })

    # Migration contract check in runtime payload: route now carries sources + active_source_id.
    route_before_start = E2EHelpers.api_get_route!(base_url, token, route_id)
    assert is_list(route_before_start["sources"])
    assert Enum.any?(route_before_start["sources"], &(&1["position"] == 0))

    :ok =
      E2EHelpers.api_create_destination!(base_url, token, route_id, %{
        "schema" => "UDP",
        "name" => "udp_dest_failover_e2e",
        "schema_options" => %{
          "host" => "127.0.0.1",
          "port" => udp_dest_port
        }
      })

    # Same order as cascading test: SRT caller before route so connection can retry
    # until Hydra's listener is up (avoids CI flakes when the route starts before ffmpeg).
    tx_primary =
      start_sender!("ffmpeg_failover_primary", primary_source_port, 440, 60)

    on_exit(fn -> E2EHelpers.kill_port(tx_primary) end)

    :ok = E2EHelpers.api_start_route!(base_url, token, route_id)
    Process.sleep(E2EHelpers.e2e_startup_sleep_ms())

    E2EHelpers.wait_for_route_processing!(base_url, token, route_id, timeout_ms: 25_000)

    assert {:ok, %{bytes: bytes_before_switch}} =
             E2EHelpers.await_udp_bytes(udp_counter, 15_000, 8_000)

    assert bytes_before_switch > 0
    E2EHelpers.kill_port(tx_primary)

    :ok = api_switch_source!(base_url, token, route_id, backup_source_id)
    Process.sleep(E2EHelpers.e2e_startup_sleep_ms())

    tx_backup =
      start_sender!("ffmpeg_failover_backup", backup_source_port, 880, 30)

    on_exit(fn -> E2EHelpers.kill_port(tx_backup) end)

    assert {:ok, %{bytes: bytes_after_switch}} =
             E2EHelpers.await_udp_bytes(udp_counter, bytes_before_switch + 12_000, 8_000)

    assert bytes_after_switch > bytes_before_switch
    # Backup sender runs up to ~30s; allow enough time for await vs short CI timeouts.
    # Some ffmpeg builds exit 251 after data was already delivered; bytes are the main signal.
    assert E2EHelpers.await_tag_exit_status("ffmpeg_failover_backup", 40_000) in [0, 251]

    route_after_switch = E2EHelpers.api_get_route!(base_url, token, route_id)
    assert route_after_switch["active_source_id"] == backup_source_id
    assert route_after_switch["last_switch_reason"] == "manual"

    events = wait_for_route_events(base_url, token, route_id, 12_000)

    assert Enum.any?(events, fn event ->
             event["event_type"] == "source_switch" and
               event["to_source_id"] == backup_source_id and
               event["reason"] == "manual"
           end)

    assert primary_source_id != backup_source_id
  end

  test "cascading failover switches across backups and skips disabled source", %{
    base_url: base_url
  } do
    token = E2EHelpers.api_login!(base_url, "admin", "password123")

    p0 = E2EHelpers.tcp_free_port!()
    p1 = E2EHelpers.tcp_free_port!()
    p2 = E2EHelpers.tcp_free_port!()
    udp_dest_port = E2EHelpers.udp_free_port!()

    udp_counter = E2EHelpers.start_udp_counter!(udp_dest_port)
    on_exit(fn -> E2EHelpers.stop_udp_counter!(udp_counter) end)

    route_id =
      E2EHelpers.api_create_route!(base_url, token, %{
        "name" => "e2e_srt_failover_cascading",
        "backup_config" => %{
          "mode" => "passive",
          "switch_after_ms" => 1000,
          "cooldown_ms" => 1000
        }
      })

    on_exit(fn ->
      E2EHelpers.api_stop_route(base_url, token, route_id)
      E2EHelpers.api_delete_route(base_url, token, route_id)
    end)

    s0 =
      E2EHelpers.api_create_source!(base_url, token, route_id, %{
        "position" => 0,
        "enabled" => true,
        "name" => "primary-cascade",
        "schema" => "SRT",
        "schema_options" => %{
          "localaddress" => "127.0.0.1",
          "localport" => p0,
          "mode" => "listener"
        }
      })

    s1 =
      E2EHelpers.api_create_source!(base_url, token, route_id, %{
        "position" => 1,
        "enabled" => true,
        "name" => "backup-1-cascade",
        "schema" => "SRT",
        "schema_options" => %{
          "localaddress" => "127.0.0.1",
          "localport" => p1,
          "mode" => "listener"
        }
      })

    s2 =
      E2EHelpers.api_create_source!(base_url, token, route_id, %{
        "position" => 2,
        "enabled" => true,
        "name" => "backup-2-cascade",
        "schema" => "SRT",
        "schema_options" => %{
          "localaddress" => "127.0.0.1",
          "localport" => p2,
          "mode" => "listener"
        }
      })

    :ok =
      E2EHelpers.api_create_destination!(base_url, token, route_id, %{
        "schema" => "UDP",
        "name" => "udp_dest_failover_cascade_e2e",
        "schema_options" => %{"host" => "127.0.0.1", "port" => udp_dest_port}
      })

    tx_primary =
      start_sender!("ffmpeg_failover_cascade_primary", p0, 440, 20)

    on_exit(fn -> E2EHelpers.kill_port(tx_primary) end)

    :ok = E2EHelpers.api_start_route!(base_url, token, route_id)
    Process.sleep(if(System.get_env("CI") == "true", do: 1_500, else: 400))
    E2EHelpers.wait_for_route_processing!(base_url, token, route_id, timeout_ms: 25_000)

    assert {:ok, %{bytes: bytes_before}} = E2EHelpers.await_udp_bytes(udp_counter, 10_000, 8_000)
    assert bytes_before > 0

    E2EHelpers.kill_port(tx_primary)

    tx_backup1 =
      start_sender!("ffmpeg_failover_cascade_backup1", p1, 660, 20)

    on_exit(fn -> E2EHelpers.kill_port(tx_backup1) end)

    assert :ok = wait_for_active_source(base_url, token, route_id, s1, 12_000)

    :ok = api_update_source!(base_url, token, route_id, s1, %{"enabled" => false})
    E2EHelpers.kill_port(tx_backup1)

    tx_backup2 =
      start_sender!("ffmpeg_failover_cascade_backup2", p2, 880, 20)

    on_exit(fn -> E2EHelpers.kill_port(tx_backup2) end)

    assert :ok = wait_for_active_source(base_url, token, route_id, s2, 15_000)

    assert {:ok, %{bytes: bytes_after}} =
             E2EHelpers.await_udp_bytes(udp_counter, bytes_before + 15_000, 10_000)

    assert bytes_after > bytes_before

    # EventLogger flushes to DuckDB on a ~5s timer; polling until the window ends
    # avoids returning the first partial batch (see wait_for_route_events/4).
    events = wait_for_route_events(base_url, token, route_id, 14_000)

    assert Enum.any?(events, fn event ->
             event["event_type"] == "source_switch" and event["to_source_id"] == s1
           end)

    assert Enum.any?(events, fn event ->
             event["event_type"] == "source_switch" and event["to_source_id"] == s2
           end)

    assert s0 != s1 and s1 != s2
  end

  defp api_switch_source!(base_url, token, route_id, source_id) do
    body = Jason.encode!(%{"source_id" => source_id})
    do_api_switch_source(base_url, token, route_id, body, 6)
  end

  defp do_api_switch_source(_base_url, _token, _route_id, _body, 0),
    do: raise("failed to switch source after retries")

  defp do_api_switch_source(base_url, token, route_id, body, attempts_left) do
    case E2EHelpers.http_raw(
           :post,
           base_url <> "/api/routes/#{route_id}/switch-source",
           E2EHelpers.auth_headers(token),
           body
         ) do
      {:ok, 200, _headers, _resp} ->
        :ok

      {:ok, 409, _headers, _resp} ->
        Process.sleep(200)
        do_api_switch_source(base_url, token, route_id, body, attempts_left - 1)

      other ->
        raise("switch-source failed: #{inspect(other)}")
    end
  end

  defp api_update_source!(base_url, token, route_id, source_id, attrs) do
    body = Jason.encode!(%{"source" => attrs})

    {:ok, 200, _headers, _resp} =
      E2EHelpers.http_raw(
        :patch,
        base_url <> "/api/routes/#{route_id}/sources/#{source_id}",
        E2EHelpers.auth_headers(token),
        body
      )

    :ok
  end

  defp api_list_route_events!(base_url, token, route_id) do
    {:ok, 200, _headers, resp} =
      E2EHelpers.http_raw(
        :get,
        base_url <> "/api/routes/#{route_id}/events?window=last_hour&limit=200",
        E2EHelpers.auth_headers(token),
        ""
      )

    Jason.decode!(resp) |> get_in(["data", "events"]) || []
  end

  defp wait_for_route_events(base_url, token, route_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_route_events(base_url, token, route_id, deadline, [])
  end

  # Poll until the deadline and return the longest event list seen. EventLogger
  # batches writes (~5s), so the first non-empty API response is often incomplete.
  defp do_wait_for_route_events(base_url, token, route_id, deadline, best) do
    events = api_list_route_events!(base_url, token, route_id)
    best = if length(events) >= length(best), do: events, else: best

    if System.monotonic_time(:millisecond) >= deadline do
      best
    else
      Process.sleep(400)
      do_wait_for_route_events(base_url, token, route_id, deadline, best)
    end
  end

  defp wait_for_active_source(base_url, token, route_id, source_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_active_source(base_url, token, route_id, source_id, deadline)
  end

  defp do_wait_for_active_source(base_url, token, route_id, source_id, deadline) do
    route = E2EHelpers.api_get_route!(base_url, token, route_id)

    if route["active_source_id"] == source_id do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk(
          "timeout waiting for active_source_id=#{source_id}, got #{inspect(route["active_source_id"])}"
        )
      end

      Process.sleep(300)
      do_wait_for_active_source(base_url, token, route_id, source_id, deadline)
    end
  end

  defp start_sender!(tag, port, tone_hz, duration_sec) do
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
        "testsrc2=size=320x180:rate=15",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=#{tone_hz}:sample_rate=48000",
        "-t",
        Integer.to_string(duration_sec),
        "-c:v",
        "libx264",
        "-preset",
        "ultrafast",
        "-tune",
        "zerolatency",
        "-pix_fmt",
        "yuv420p",
        "-g",
        "50",
        "-c:a",
        "aac",
        "-b:a",
        "96k",
        "-ar",
        "48000",
        "-ac",
        "2",
        "-f",
        "mpegts",
        "srt://127.0.0.1:#{port}?mode=caller"
      ],
      tag
    )
  end
end

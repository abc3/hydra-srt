defmodule HydraSrt.Ndi.Discovery do
  @moduledoc """
  Supervised NDI discovery coordinator.

  Owns at most one native `ndi-discovery` helper OS process when
  `HydraSrt.Ndi.FeaturePolicy.enabled?/0` is true. Holds a non-authoritative
  device snapshot with monotonic `refreshed_at` and reports staleness after 15s.

  Accepts an injectable `:port_launcher` (default = real `Port.open/2`) so tests
  can drive the same `{port, {:data, _}}` / `{port, {:exit_status, _}}` messages
  a Port would deliver without the native binary.
  """

  use GenServer
  require Logger

  alias HydraSrt.Ndi.FeaturePolicy

  @stale_after_ms :timer.seconds(15)
  # Native snapshot max (ndi_discovery.rs): 256 devices × 4 fields × 256-byte
  # sanitized strings. Per-device JSON is ~1.1KB; envelope ~200B → ~310KB.
  # Guard at 512KB so a full snapshot is accepted; true oversize is skipped,
  # marked unhealthy, and refreshable (not silently coalesced away).
  @max_line_bytes 524_288
  @max_devices 256
  @min_backoff_ms :timer.seconds(1)
  @max_backoff_ms :timer.seconds(30)
  @unhealthy_after_failures 5

  # Device maps are JSON-derived with sanitized string keys/values; typespecs
  # cannot enumerate string-literal keys, so use a string-keyed map type.
  @type device :: %{optional(String.t()) => String.t()}

  @type capability :: %{
          ok: boolean(),
          reason_code: String.t() | nil
        }

  @type snapshot :: %{
          devices: [device()],
          stale: boolean(),
          capability: capability(),
          truncated: boolean()
        }

  @type port_handle :: port() | reference()
  @type port_launcher :: (String.t(), [String.t()] -> port_handle())
  @type backoff_fun :: (pos_integer() -> pos_integer())
  @type helper_exit_status :: integer() | :port_exit | :launch_failed
  @type helper_payload :: map()

  @type state :: %{
          port: port_handle() | nil,
          helper_instance_id: String.t() | nil,
          buffer: binary(),
          devices: [device()],
          truncated: boolean(),
          capability: capability(),
          refreshed_at_ms: integer() | nil,
          consecutive_failures: non_neg_integer(),
          restart_timer_ref: reference() | nil,
          refresh_in_flight: boolean(),
          refresh_pending: boolean(),
          port_launcher: port_launcher(),
          stale_after_ms: pos_integer(),
          binary_path: String.t(),
          backoff_fun: backoff_fun(),
          spawn_enabled: boolean()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec snapshot(GenServer.server()) :: snapshot()
  def snapshot(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> %{devices: [], stale: true, capability: disabled_capability(), truncated: false}
      pid -> GenServer.call(pid, :snapshot)
    end
  end

  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> :ok
      pid -> GenServer.call(pid, :refresh)
    end
  end

  @doc """
  Bounded exponential backoff with jitter for helper restarts.

  Base delay is `min(30_000, 1_000 * 2^(failures-1))` milliseconds, then a
  positive jitter of up to 25% of the base is added. Caps at 30s before jitter.
  """
  @spec next_backoff_ms(pos_integer()) :: pos_integer()
  def next_backoff_ms(failures) when is_integer(failures) and failures >= 1 do
    shift = min(failures - 1, 5)
    base = min(@max_backoff_ms, @min_backoff_ms * Integer.pow(2, shift))
    jitter = :rand.uniform(div(base, 4) + 1)
    base + jitter
  end

  @spec binary_path() :: String.t()
  def binary_path do
    Path.join([:code.priv_dir(:hydra_srt), "native", "hydra_srt_pipeline"])
  end

  @spec native_discovery_args(String.t()) :: [String.t()]
  def native_discovery_args(helper_instance_id) when is_binary(helper_instance_id) do
    ["ndi-discovery", "--helper-instance-id", helper_instance_id]
  end

  @doc """
  Port env for the discovery helper OS process.

  Quiet GStreamer debug plus the same `HYDRA_NDI_RUNTIME_DIR` →
  `NDI_RUNTIME_DIR_V6` mapping used by `RouteHandler` for route pipelines.
  """
  @spec discovery_port_env() :: [{charlist(), charlist()}]
  def discovery_port_env do
    base = [{~c"GST_DEBUG", ~c"0"}, {~c"GST_DEBUG_NO_COLOR", ~c"1"}]

    case System.get_env("HYDRA_NDI_RUNTIME_DIR") do
      dir when is_binary(dir) and dir != "" ->
        base ++ [{~c"NDI_RUNTIME_DIR_V6", String.to_charlist(dir)}]

      _ ->
        base
    end
  end

  @spec default_port_launcher(String.t(), [String.t()]) :: port()
  def default_port_launcher(binary_path, args)
      when is_binary(binary_path) and is_list(args) do
    base_opts = [
      :stderr_to_stdout,
      :use_stdio,
      :binary,
      :exit_status,
      :stream,
      args: Enum.map(args, &String.to_charlist/1),
      env: discovery_port_env()
    ]

    Port.open({:spawn_executable, String.to_charlist(binary_path)}, base_opts)
  end

  @spec disabled_capability() :: capability()
  def disabled_capability do
    %{ok: false, reason_code: "NDI_DISABLED"}
  end

  @spec unhealthy_capability() :: capability()
  def unhealthy_capability do
    %{ok: false, reason_code: "NDI_HELPER_UNHEALTHY"}
  end

  @spec pending_capability() :: capability()
  def pending_capability do
    %{ok: false, reason_code: "NDI_HELPER_PENDING"}
  end

  @spec ok_capability() :: capability()
  def ok_capability do
    %{ok: true, reason_code: nil}
  end

  @spec max_line_bytes() :: pos_integer()
  def max_line_bytes, do: @max_line_bytes

  @spec max_devices() :: pos_integer()
  def max_devices, do: @max_devices

  @spec normalize_device(term()) :: device() | nil
  def normalize_device(raw) when is_map(raw) do
    display_name = device_field(raw, "display_name")

    if is_binary(display_name) and display_name != "" do
      %{
        "display_name" => display_name,
        "device_class" => device_field(raw, "device_class") || "",
        "caps" => device_field(raw, "caps") || "",
        "properties" => device_field(raw, "properties") || ""
      }
    else
      nil
    end
  end

  def normalize_device(_), do: nil

  @spec device_field(map(), String.t()) :: String.t() | nil
  def device_field(raw, key) when is_map(raw) and is_binary(key) do
    case Map.get(raw, key) do
      value when is_binary(value) ->
        value

      _ ->
        atom_key =
          case key do
            "display_name" -> :display_name
            "device_class" -> :device_class
            "caps" -> :caps
            "properties" -> :properties
            _ -> nil
          end

        case atom_key && Map.get(raw, atom_key) do
          value when is_binary(value) -> value
          _ -> nil
        end
    end
  end

  @doc """
  Splits Port chunks into complete JSONL lines.

  Returns `{:ok, lines, rest, oversized?}` — an oversize line is skipped and
  parsing continues on the remainder of the chunk (does not discard later lines).
  """
  @spec append_port_data(binary(), binary()) ::
          {:ok, [binary()], binary(), boolean()}
  def append_port_data(buffer, chunk) when is_binary(buffer) and is_binary(chunk) do
    combined = buffer <> chunk
    split_complete_lines(combined, [], false)
  end

  @spec split_complete_lines(binary(), [binary()], boolean()) ::
          {:ok, [binary()], binary(), boolean()}
  def split_complete_lines(buffer, acc, oversized) do
    case :binary.split(buffer, "\n") do
      [line, rest] ->
        if byte_size(line) > @max_line_bytes do
          split_complete_lines(rest, acc, true)
        else
          split_complete_lines(rest, [line | acc], oversized)
        end

      [rest] ->
        if byte_size(rest) > @max_line_bytes do
          {:ok, Enum.reverse(acc), "", true}
        else
          {:ok, Enum.reverse(acc), rest, oversized}
        end
    end
  end

  @spec apply_devices_cap([device()], boolean()) :: {[device()], boolean()}
  def apply_devices_cap(devices, truncated) when is_list(devices) do
    count = length(devices)
    # Coerce with == true so a nil/non-boolean never hits strict `or` (ArgumentError).
    truncated? = truncated == true

    if count > @max_devices do
      # Evict oldest entries; keep the newest @max_devices (tail).
      {Enum.drop(devices, count - @max_devices), true}
    else
      {devices, truncated?}
    end
  end

  @spec upsert_device([device()], device()) :: {[device()], boolean()}
  def upsert_device(devices, device) when is_list(devices) and is_map(device) do
    name = device["display_name"]
    without = Enum.reject(devices, &(&1["display_name"] == name))
    apply_devices_cap(without ++ [device], false)
  end

  @spec remove_device([device()], device()) :: [device()]
  def remove_device(devices, device) when is_list(devices) and is_map(device) do
    name = device["display_name"]
    Enum.reject(devices, &(&1["display_name"] == name))
  end

  @spec snapshot_stale?(integer() | nil, integer(), pos_integer()) :: boolean()
  def snapshot_stale?(nil, _now_ms, _stale_after_ms), do: true

  def snapshot_stale?(refreshed_at_ms, now_ms, stale_after_ms)
      when is_integer(refreshed_at_ms) and is_integer(now_ms) and is_integer(stale_after_ms) do
    now_ms - refreshed_at_ms > stale_after_ms
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    port_launcher = Keyword.get(opts, :port_launcher, &default_port_launcher/2)
    stale_after_ms = Keyword.get(opts, :stale_after_ms, @stale_after_ms)
    binary_path = Keyword.get(opts, :binary_path, binary_path())
    backoff_fun = Keyword.get(opts, :backoff_fun, &next_backoff_ms/1)

    spawn_enabled = FeaturePolicy.enabled?()

    state = %{
      port: nil,
      helper_instance_id: nil,
      buffer: "",
      devices: [],
      truncated: false,
      capability:
        if spawn_enabled do
          pending_capability()
        else
          disabled_capability()
        end,
      refreshed_at_ms: nil,
      consecutive_failures: 0,
      restart_timer_ref: nil,
      refresh_in_flight: false,
      refresh_pending: false,
      port_launcher: port_launcher,
      stale_after_ms: stale_after_ms,
      binary_path: binary_path,
      backoff_fun: backoff_fun,
      spawn_enabled: spawn_enabled
    }

    # Defer Port.open off the supervisor start path (slow/failing helper must
    # not stall Application/Ndi.Supervisor init).
    {:ok, state, {:continue, :start_helper}}
  end

  @impl true
  def handle_continue(:start_helper, state) do
    {:noreply, maybe_spawn_helper(sync_spawn_enabled(state))}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, build_snapshot(state), state}
  end

  def handle_call(:refresh, _from, state) do
    state = sync_spawn_enabled(state)

    cond do
      not state.spawn_enabled ->
        {:reply, :ok, state}

      state.refresh_in_flight ->
        {:reply, :ok, %{state | refresh_pending: true}}

      true ->
        {:reply, :ok, begin_refresh(state)}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) when is_binary(data) do
    {:noreply, handle_port_data(state, data)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:noreply, handle_helper_exit(state, status)}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state) do
    {:noreply, handle_helper_exit(state, :port_exit)}
  end

  def handle_info(:restart_helper, state) do
    state = %{state | restart_timer_ref: nil}
    state = sync_spawn_enabled(state)

    if state.spawn_enabled and is_nil(state.port) do
      {:noreply, spawn_helper(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = cancel_restart_timer(state)
    _ = close_helper_port(state)
    :ok
  end

  @spec sync_spawn_enabled(state()) :: state()
  def sync_spawn_enabled(state) do
    enabled = FeaturePolicy.enabled?()

    cond do
      enabled == state.spawn_enabled ->
        state

      enabled ->
        %{
          state
          | spawn_enabled: true,
            capability: pending_capability(),
            consecutive_failures: 0,
            refreshed_at_ms: nil
        }

      true ->
        state
        |> cancel_restart_timer()
        |> close_helper_port()
        |> Map.merge(%{
          spawn_enabled: false,
          capability: disabled_capability(),
          devices: [],
          truncated: false,
          buffer: "",
          refresh_in_flight: false,
          refresh_pending: false,
          consecutive_failures: 0,
          refreshed_at_ms: monotonic_ms()
        })
    end
  end

  @spec begin_refresh(state()) :: state()
  def begin_refresh(state) do
    state
    |> cancel_restart_timer()
    |> close_helper_port()
    |> Map.put(:refresh_in_flight, true)
    |> Map.put(:refresh_pending, false)
    |> Map.put(:buffer, "")
    |> Map.put(:capability, pending_capability())
    |> spawn_helper()
  end

  @spec maybe_spawn_helper(state()) :: state()
  def maybe_spawn_helper(state) do
    if state.spawn_enabled do
      spawn_helper(state)
    else
      %{
        state
        | capability: disabled_capability(),
          devices: [],
          truncated: false,
          refreshed_at_ms: monotonic_ms()
      }
    end
  end

  @spec spawn_helper(state()) :: state()
  def spawn_helper(state) do
    helper_instance_id = Ecto.UUID.generate()
    args = native_discovery_args(helper_instance_id)

    try do
      port = state.port_launcher.(state.binary_path, args)

      %{
        state
        | port: port,
          helper_instance_id: helper_instance_id,
          buffer: ""
      }
    rescue
      error ->
        Logger.error("Ndi.Discovery: failed to launch helper: #{Exception.message(error)}")

        # Clear coalesce flags before exit handling so launch failure cannot
        # recurse through maybe_run_pending_refresh → begin_refresh → spawn_helper.
        handle_helper_exit(
          %{
            state
            | port: nil,
              helper_instance_id: helper_instance_id,
              refresh_in_flight: false,
              refresh_pending: false
          },
          :launch_failed
        )
    end
  end

  @spec handle_port_data(state(), binary()) :: state()
  def handle_port_data(state, data) when is_map(state) and is_binary(data) do
    try do
      apply_port_data(state, data)
    rescue
      error ->
        Logger.error(
          "Ndi.Discovery: port data handler crashed: #{Exception.format(:error, error, __STACKTRACE__)}"
        )

        recover_after_port_data_fault(state)
    catch
      kind, reason ->
        Logger.error("Ndi.Discovery: port data handler #{kind}: #{inspect(reason)}")
        recover_after_port_data_fault(state)
    end
  end

  @spec apply_port_data(state(), binary()) :: state()
  def apply_port_data(state, data) when is_map(state) and is_binary(data) do
    # Keep this `case` in lockstep with append_port_data/2's 4-tuple return.
    # A 3-tuple / {:error,:line_too_long} hybrid raises CaseClauseError here and
    # would kill the coordinator on the first {:data,_} without handle_port_data/2.
    case append_port_data(state.buffer, data) do
      {:ok, lines, buffer, oversized} when is_list(lines) and is_binary(buffer) ->
        state =
          Enum.reduce(lines, %{state | buffer: buffer}, fn line, acc ->
            handle_helper_line(line, acc)
          end)

        if oversized do
          # Skip the bad line (finding 6 already kept later lines). If this chunk
          # had no usable lines, mark unhealthy and clear coalesce (findings 1+3).
          usable? = Enum.any?(lines, &(&1 != ""))
          handle_oversized_line(state, not usable?)
        else
          state
        end

      other ->
        Logger.error("Ndi.Discovery: unexpected append_port_data result: #{inspect(other)}")
        recover_after_port_data_fault(state)
    end
  end

  @spec recover_after_port_data_fault(state()) :: state()
  def recover_after_port_data_fault(state) do
    pending? = state.refresh_in_flight || state.refresh_pending || false

    state = %{
      state
      | buffer: "",
        capability: unhealthy_capability(),
        refresh_in_flight: false,
        refresh_pending: pending? == true
    }

    maybe_run_pending_refresh(state)
  end

  @spec handle_oversized_line(state(), boolean()) :: state()
  def handle_oversized_line(state, mark_unhealthy) do
    Logger.warning("Ndi.Discovery: skipped oversized helper line (>#{@max_line_bytes} bytes)")

    # Always clear a stuck refresh_in_flight and trailing-edge schedule when the
    # guard fires during an in-flight refresh (finding 3). Mark unhealthy only
    # when the chunk produced no usable lines (finding 1) so a later valid line
    # in the same chunk keeps its capability (finding 6).
    # Use || (not `or`) so accidental nil flags cannot raise ArgumentError.
    refresh_pending = state.refresh_pending || state.refresh_in_flight || false

    state = %{
      state
      | buffer: "",
        refresh_in_flight: false,
        refresh_pending: refresh_pending == true
    }

    state =
      if mark_unhealthy do
        %{state | capability: unhealthy_capability()}
      else
        state
      end

    maybe_run_pending_refresh(state)
  end

  @spec finish_refresh_in_flight(state()) :: state()
  def finish_refresh_in_flight(state) do
    state = %{state | refresh_in_flight: false}
    maybe_run_pending_refresh(state)
  end

  @spec maybe_run_pending_refresh(state()) :: state()
  def maybe_run_pending_refresh(%{refresh_pending: true, spawn_enabled: true} = state) do
    begin_refresh(state)
  end

  def maybe_run_pending_refresh(state), do: state

  @spec handle_helper_line(binary(), state()) :: state()
  def handle_helper_line("", state), do: state

  def handle_helper_line(line, state) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{"event" => event} = payload} ->
        handle_helper_event(event, payload, state)

      {:ok, _} ->
        state

      {:error, _} ->
        Logger.debug("Ndi.Discovery: ignoring non-JSON helper line")
        state
    end
  end

  @spec handle_helper_event(String.t(), helper_payload(), state()) :: state()
  def handle_helper_event("ndi_device_snapshot", payload, state) do
    devices =
      payload
      |> Map.get("devices", [])
      |> List.wrap()
      |> Enum.map(&normalize_device/1)
      |> Enum.reject(&is_nil/1)

    truncated = Map.get(payload, "truncated", false) == true
    {devices, truncated} = apply_devices_cap(devices, truncated)

    %{
      state
      | devices: devices,
        truncated: truncated,
        capability: ok_capability(),
        refreshed_at_ms: monotonic_ms(),
        consecutive_failures: 0
    }
    |> finish_refresh_in_flight()
  end

  def handle_helper_event("ndi_device_added", payload, state) do
    case normalize_device(Map.get(payload, "device")) do
      nil ->
        state

      device ->
        {devices, truncated} = upsert_device(state.devices, device)

        %{
          state
          | devices: devices,
            truncated: state.truncated || truncated,
            refreshed_at_ms: monotonic_ms(),
            consecutive_failures: 0
        }
        |> finish_refresh_in_flight()
    end
  end

  def handle_helper_event("ndi_device_removed", payload, state) do
    case normalize_device(Map.get(payload, "device")) do
      nil ->
        state

      device ->
        %{
          state
          | devices: remove_device(state.devices, device),
            refreshed_at_ms: monotonic_ms(),
            consecutive_failures: 0
        }
        |> finish_refresh_in_flight()
    end
  end

  def handle_helper_event("ndi_capability", payload, state) do
    ok = Map.get(payload, "ok") == true
    reason_code = Map.get(payload, "reason_code")

    capability = %{
      ok: ok,
      reason_code: if(is_binary(reason_code), do: reason_code, else: nil)
    }

    # Reset consecutive_failures ONLY on genuine success (ok: true). An
    # ok: false capability (plugin/runtime missing) must not zero the counter,
    # or NDI_HELPER_UNHEALTHY never triggers across exit loops.
    failures =
      if ok do
        0
      else
        state.consecutive_failures
      end

    %{
      state
      | capability: capability,
        refreshed_at_ms: monotonic_ms(),
        consecutive_failures: failures
    }
    |> finish_refresh_in_flight()
  end

  def handle_helper_event(_event, _payload, state), do: state

  @spec handle_helper_exit(state(), helper_exit_status()) :: state()
  def handle_helper_exit(state, status) do
    failures = state.consecutive_failures + 1

    Logger.warning(
      "Ndi.Discovery: helper exited status=#{inspect(status)} consecutive_failures=#{failures}"
    )

    capability =
      if failures >= @unhealthy_after_failures do
        unhealthy_capability()
      else
        pending_capability()
      end

    state = %{
      state
      | port: nil,
        helper_instance_id: nil,
        buffer: "",
        consecutive_failures: failures,
        capability: capability
    }

    state = finish_refresh_in_flight(state)

    if state.spawn_enabled and not state.refresh_in_flight do
      schedule_restart(state, failures)
    else
      state
    end
  end

  @spec schedule_restart(state(), pos_integer()) :: state()
  def schedule_restart(state, failures) do
    state = cancel_restart_timer(state)
    delay_ms = state.backoff_fun.(failures)
    ref = Process.send_after(self(), :restart_helper, delay_ms)
    %{state | restart_timer_ref: ref}
  end

  @spec cancel_restart_timer(state()) :: state()
  def cancel_restart_timer(%{restart_timer_ref: nil} = state), do: state

  def cancel_restart_timer(%{restart_timer_ref: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | restart_timer_ref: nil}
  end

  @spec close_helper_port(state()) :: state()
  def close_helper_port(%{port: nil} = state), do: state

  def close_helper_port(%{port: port} = state) do
    if is_port(port) do
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end
    end

    %{state | port: nil, helper_instance_id: nil}
  end

  @spec build_snapshot(state()) :: snapshot()
  def build_snapshot(state) do
    now_ms = monotonic_ms()

    %{
      devices: state.devices,
      stale: snapshot_stale?(state.refreshed_at_ms, now_ms, state.stale_after_ms),
      capability: state.capability,
      truncated: state.truncated
    }
  end

  @spec monotonic_ms() :: integer()
  def monotonic_ms do
    System.monotonic_time(:millisecond)
  end
end

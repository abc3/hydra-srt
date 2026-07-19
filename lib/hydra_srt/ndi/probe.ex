defmodule HydraSrt.Ndi.Probe do
  @moduledoc """
  Bounded OTP wrapper around the native `ndi-probe` CLI.

  Spawns `priv/native/hydra_srt_pipeline ndi-probe --probe-instance-id <uuid>`,
  writes one typed NDI source endpoint JSON line on stdin, collects the single
  `probe_result` JSONL event, then cleans up. Never mutates active routes.

  Injectable `:port_launcher` / `:port_commander` keep unit tests off the real
  binary (same Port message shape as `HydraSrt.Ndi.Discovery`).
  """

  require Logger

  alias HydraSrt.Ndi.FeaturePolicy
  alias HydraSrt.RouteHandler

  @default_timeout_ms :timer.seconds(15)
  @max_line_bytes 65_536

  @type port_handle :: port() | reference()
  @type port_launcher :: (String.t(), [String.t()] -> port_handle())
  @type port_commander :: (port_handle(), binary() -> :ok | {:error, term()})
  @type closer :: (port_handle() -> :ok)

  @type probe_input :: map()

  @type probe_result :: %{
          ok: boolean(),
          code: String.t() | nil,
          probe_instance_id: String.t(),
          video_caps: String.t() | nil,
          audio_caps: String.t() | nil,
          frames: %{video: non_neg_integer(), audio: non_neg_integer()},
          skew_ms: number() | nil,
          elapsed_ms: non_neg_integer(),
          detail: String.t() | nil
        }

  @type error_result :: {:error, String.t(), String.t()}

  @doc """
  Runs a bounded NDI probe against a typed source config map.

  `source` must already be the wire shape `%{"id" => ..., "kind" => "ndi", "ndi" => ...}`
  or a RouteHandler-compatible source record that `source_from_record/2` accepts
  (when `:route` is provided).

  Options:
  - `:timeout_ms` (default 15s)
  - `:port_launcher`, `:port_commander`, `:port_closer` (tests)
  - `:binary_path`
  - `:route` — route map used when `source` is a DB/API record
  - `:probe_instance_id` — fixed id for tests
  """
  @spec run(probe_input(), keyword()) :: {:ok, probe_result()} | error_result()
  def run(source, opts \\ []) when is_map(source) and is_list(opts) do
    case FeaturePolicy.deny_reason(:receive) do
      reason when is_binary(reason) ->
        {:error, reason, "NDI receive is disabled"}

      nil ->
        with {:ok, wire_source} <- normalize_source(source, opts) do
          execute_probe(wire_source, opts)
        end
    end
  end

  @doc """
  Builds native probe stdin payload from a typed NDI source endpoint.
  """
  @spec probe_stdin_payload(map()) :: map()
  def probe_stdin_payload(%{"kind" => "ndi", "ndi" => ndi} = source) when is_map(ndi) do
    %{
      "source" => %{
        "id" => source["id"] || source[:id] || Ecto.UUID.generate(),
        "kind" => "ndi",
        "ndi" => ndi
      }
    }
  end

  def probe_stdin_payload(source) when is_map(source) do
    %{
      "source" => source
    }
  end

  @spec binary_path() :: String.t()
  def binary_path do
    Path.join([:code.priv_dir(:hydra_srt), "native", "hydra_srt_pipeline"])
  end

  @spec native_probe_args(String.t()) :: [String.t()]
  def native_probe_args(probe_instance_id) when is_binary(probe_instance_id) do
    ["ndi-probe", "--probe-instance-id", probe_instance_id]
  end

  @doc """
  Port env for the probe OS process (quiet GStreamer + NDI runtime dir mapping).
  """
  @spec probe_port_env() :: [{charlist(), charlist()}]
  def probe_port_env do
    [{~c"GST_DEBUG", ~c"0"}, {~c"GST_DEBUG_NO_COLOR", ~c"1"}] ++
      RouteHandler.ndi_runtime_port_env()
  end

  @spec default_port_launcher(String.t(), [String.t()]) :: port()
  def default_port_launcher(binary_path, args)
      when is_binary(binary_path) and is_list(args) do
    Port.open(
      {:spawn_executable, String.to_charlist(binary_path)},
      [
        :stderr_to_stdout,
        :use_stdio,
        :binary,
        :exit_status,
        :stream,
        args: Enum.map(args, &String.to_charlist/1),
        env: probe_port_env()
      ]
    )
  end

  @spec default_port_commander(port_handle(), binary()) :: :ok | {:error, term()}
  def default_port_commander(port, payload) when is_binary(payload) do
    if is_port(port) do
      case Port.info(port) do
        nil ->
          {:error, :closed}

        _info ->
          try do
            case Port.command(port, payload) do
              true -> :ok
              false -> {:error, :closed}
            end
          rescue
            ArgumentError -> {:error, :closed}
          end
      end
    else
      # Fake handles used in tests: commander is responsible for delivering replies.
      :ok
    end
  end

  @spec default_port_closer(port_handle()) :: :ok
  def default_port_closer(port) do
    if is_port(port) do
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  @spec normalize_source(map(), keyword()) :: {:ok, map()} | error_result()
  def normalize_source(source, opts) when is_map(source) and is_list(opts) do
    cond do
      match?(%{"kind" => "ndi", "ndi" => %{}}, source) ->
        {:ok, stringify_keys(source)}

      match?(%{kind: "ndi", ndi: %{}}, source) ->
        {:ok, stringify_keys(source)}

      source["schema"] == "NDI" or source[:schema] == "NDI" ->
        route = Keyword.get(opts, :route, %{"id" => "probe", "name" => "probe"})

        case RouteHandler.source_from_record(stringify_keys(source), stringify_keys(route)) do
          {:ok, %{"kind" => "ndi", "ndi" => ndi}} when is_map(ndi) ->
            {:ok,
             %{
               "id" => source["id"] || source[:id] || Ecto.UUID.generate(),
               "kind" => "ndi",
               "ndi" => ndi
             }}

          {:error, _reason} ->
            {:error, "NDI_CONFIG_INVALID", "Invalid NDI source configuration"}
        end

      true ->
        {:error, "NDI_CONFIG_INVALID", "Probe requires an NDI source endpoint"}
    end
  end

  @spec execute_probe(map(), keyword()) :: {:ok, probe_result()} | error_result()
  def execute_probe(wire_source, opts) when is_map(wire_source) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    binary_path = Keyword.get(opts, :binary_path, binary_path())
    port_launcher = Keyword.get(opts, :port_launcher, &default_port_launcher/2)
    port_commander = Keyword.get(opts, :port_commander, &default_port_commander/2)
    port_closer = Keyword.get(opts, :port_closer, &default_port_closer/1)
    probe_instance_id = Keyword.get(opts, :probe_instance_id, Ecto.UUID.generate())

    args = native_probe_args(probe_instance_id)
    payload = probe_stdin_payload(wire_source)

    with {:ok, json} <- Jason.encode(payload),
         {:ok, port} <- launch_port(port_launcher, binary_path, args),
         :ok <- port_commander.(port, json <> "\n") do
      try do
        collect_probe_result(port, probe_instance_id, "", timeout_ms)
      after
        _ = port_closer.(port)
      end
    else
      {:error, :launch_failed} ->
        {:error, "NDI_HELPER_UNHEALTHY", "Failed to launch NDI probe process"}

      {:error, %Jason.EncodeError{}} ->
        {:error, "NDI_CONFIG_INVALID", "Failed to encode probe configuration"}

      {:error, reason} when is_atom(reason) ->
        {:error, "NDI_HELPER_UNHEALTHY", "Probe stdin write failed: #{reason}"}

      {:error, code, message} ->
        {:error, code, message}
    end
  end

  @spec launch_port(port_launcher(), String.t(), [String.t()]) ::
          {:ok, port_handle()} | {:error, :launch_failed}
  def launch_port(port_launcher, binary_path, args)
      when is_function(port_launcher, 2) and is_binary(binary_path) and is_list(args) do
    try do
      {:ok, port_launcher.(binary_path, args)}
    rescue
      error ->
        Logger.error("Ndi.Probe: failed to launch: #{Exception.message(error)}")
        {:error, :launch_failed}
    end
  end

  @spec collect_probe_result(port_handle(), String.t(), binary(), non_neg_integer()) ::
          {:ok, probe_result()} | error_result()
  def collect_probe_result(port, probe_instance_id, buffer, timeout_ms)
      when is_binary(buffer) and is_integer(timeout_ms) and timeout_ms >= 0 do
    receive do
      {^port, {:data, chunk}} when is_binary(chunk) ->
        case append_port_data(buffer, chunk) do
          {:ok, lines, rest, oversized?} ->
            if oversized? do
              {:error, "NDI_HELPER_UNHEALTHY", "Probe output line exceeded size limit"}
            else
              case find_probe_result(lines, probe_instance_id) do
                {:ok, result} ->
                  {:ok, result}

                :continue ->
                  collect_probe_result(port, probe_instance_id, rest, timeout_ms)
              end
            end
        end

      {^port, {:exit_status, _status}} ->
        case find_probe_result(String.split(buffer, "\n", trim: true), probe_instance_id) do
          {:ok, result} ->
            {:ok, result}

          :continue ->
            {:error, "NDI_HELPER_UNHEALTHY", "Probe exited before emitting probe_result"}
        end

      {:EXIT, ^port, _reason} ->
        {:error, "NDI_HELPER_UNHEALTHY", "Probe port exited unexpectedly"}
    after
      timeout_ms ->
        {:error, "NDI_HELPER_UNHEALTHY", "Probe timed out"}
    end
  end

  @spec append_port_data(binary(), binary()) :: {:ok, [binary()], binary(), boolean()}
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

  @spec find_probe_result([binary()], String.t()) :: {:ok, probe_result()} | :continue
  def find_probe_result(lines, probe_instance_id) when is_list(lines) do
    Enum.find_value(lines, :continue, fn line ->
      case decode_probe_result_line(line, probe_instance_id) do
        {:ok, result} -> {:ok, result}
        :ignore -> nil
      end
    end)
  end

  @spec decode_probe_result_line(binary(), String.t()) :: {:ok, probe_result()} | :ignore
  def decode_probe_result_line("", _probe_instance_id), do: :ignore

  def decode_probe_result_line(line, probe_instance_id) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{"event" => "probe_result"} = payload} ->
        {:ok, normalize_probe_result(payload, probe_instance_id)}

      {:ok, _} ->
        :ignore

      {:error, _} ->
        :ignore
    end
  end

  @spec normalize_probe_result(map(), String.t()) :: probe_result()
  def normalize_probe_result(payload, fallback_id) when is_map(payload) do
    ok? = payload["ok"] == true
    code = payload["reason_code"] || payload["code"]

    %{
      ok: ok?,
      code: if(is_binary(code), do: code, else: if(ok?, do: nil, else: "RUNTIME_ERROR")),
      probe_instance_id: payload["probe_instance_id"] || fallback_id,
      video_caps: string_or_nil(payload["video_caps"]),
      audio_caps: string_or_nil(payload["audio_caps"]),
      frames: %{
        video: non_neg_int(payload["video_frames"] || payload["frames_video"], ok?),
        audio: non_neg_int(payload["audio_frames"] || payload["frames_audio"], ok?)
      },
      skew_ms: number_or_nil(payload["skew_ms"] || payload["av_skew_ms"]),
      elapsed_ms: non_neg_int(payload["elapsed_ms"], false),
      detail: string_or_nil(payload["detail"])
    }
  end

  @spec stringify_keys(map()) :: map()
  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_value(value)}
      {key, value} when is_binary(key) -> {key, stringify_value(value)}
    end)
  end

  @spec stringify_value(term()) :: term()
  def stringify_value(%{} = value), do: stringify_keys(value)
  def stringify_value(value), do: value

  @spec string_or_nil(term()) :: String.t() | nil
  def string_or_nil(value) when is_binary(value), do: value
  def string_or_nil(_), do: nil

  @spec number_or_nil(term()) :: number() | nil
  def number_or_nil(value) when is_number(value), do: value
  def number_or_nil(_), do: nil

  @spec non_neg_int(term(), boolean()) :: non_neg_integer()
  def non_neg_int(value, _ok?) when is_integer(value) and value >= 0, do: value
  def non_neg_int(_value, true), do: 1
  def non_neg_int(_value, false), do: 0
end

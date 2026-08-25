defmodule HydraSrt.ProcessMonitor do
  @moduledoc false
  require Logger

  alias HydraSrt.Helpers

  @type pipeline_kind :: :route | :ndi_helper | :other

  @standard_process_layout %{
    pid: 0,
    cpu: 1,
    memory_percent: 2,
    vsz: 3,
    rss: 4,
    user: 5,
    lstart: 6,
    cpu_time: nil,
    state: nil,
    ppid: nil
  }
  @detailed_process_layout %{
    pid: 0,
    cpu: 1,
    memory_percent: 2,
    vsz: 3,
    rss: 4,
    cpu_time: 5,
    state: 6,
    ppid: 7,
    user: 8,
    lstart: 9
  }
  @platform_process_layouts %{
    darwin: %{standard: @standard_process_layout, detailed: @detailed_process_layout},
    linux: %{standard: @standard_process_layout, detailed: @detailed_process_layout}
  }

  def list_pipeline_processes do
    case :os.type() do
      {:unix, :darwin} -> list_pipeline_processes_darwin()
      {:unix, :linux} -> list_pipeline_processes_linux()
      _ -> {:error, "Unsupported operating system"}
    end
  end

  def list_pipeline_processes_detailed do
    case :os.type() do
      {:unix, :darwin} -> list_pipeline_processes_detailed_darwin()
      {:unix, :linux} -> list_pipeline_processes_detailed_linux()
      _ -> {:error, "Unsupported operating system"}
    end
  end

  def kill_pipeline_processes_for_route(route_id) when is_binary(route_id) do
    case route_pipeline_processes(route_id) do
      {:error, _reason} = error ->
        error

      processes ->
        results =
          Enum.map(processes, fn %{pid: pid, command: command} ->
            Logger.error(
              "Killing stale hydra_srt_pipeline process for route_id=#{route_id} pid=#{pid} command=#{inspect(command)}"
            )

            kill_result = Helpers.sys_kill(pid)
            wait_result = Helpers.wait_for_process_exit(pid)

            {pid, kill_result, wait_result}
          end)

        {:ok, results}
    end
  end

  @doc false
  def route_pipeline_processes(route_id, processes \\ list_pipeline_processes())

  def route_pipeline_processes(_route_id, {:error, _reason} = error), do: error

  def route_pipeline_processes(route_id, processes)
      when is_binary(route_id) and is_list(processes) do
    Enum.filter(processes, &route_pipeline_process?(&1, route_id))
  end

  @doc """
  Classifies a `hydra_srt_pipeline` OS process.

  - `:route` — route media process (`route --route-id ...`)
  - `:ndi_helper` — discovery/probe helper (`ndi-discovery` / `ndi-probe`); excluded from route cleanup
  - `:other` — not a pipeline binary invocation
  """
  @spec pipeline_process_kind(%{optional(:command) => String.t()} | map()) :: pipeline_kind()
  def pipeline_process_kind(%{command: command}) when is_binary(command) do
    pipeline_process_kind_from_args(command_args(command))
  end

  def pipeline_process_kind(_process), do: :other

  @spec pipeline_process_kind_from_args([String.t()]) :: pipeline_kind()
  def pipeline_process_kind_from_args(args) when is_list(args) do
    case pipeline_binary_index(args) do
      nil ->
        :other

      index ->
        # Subcommand is the token immediately after the binary path — not bare
        # argv membership (a route id / flag value of "ndi-discovery" must stay :route).
        case Enum.at(args, index + 1) do
          "ndi-discovery" -> :ndi_helper
          "ndi-probe" -> :ndi_helper
          _ -> :route
        end
    end
  end

  @spec pipeline_binary_index([String.t()]) :: non_neg_integer() | nil
  def pipeline_binary_index(args) when is_list(args) do
    Enum.find_index(args, &(Path.basename(&1) == "hydra_srt_pipeline"))
  end

  @spec command_args(String.t()) :: [String.t()]
  def command_args(command) when is_binary(command) do
    String.split(command, ~r/\s+/, trim: true)
  end

  @doc false
  @spec route_pipeline_process?(map(), String.t()) :: boolean()
  def route_pipeline_process?(%{command: command}, route_id)
      when is_binary(command) and is_binary(route_id) do
    args = command_args(command)
    pipeline_process_kind_from_args(args) == :route and route_id in args
  end

  def route_pipeline_process?(_process, _route_id), do: false

  defp list_pipeline_processes_darwin do
    {output, 0} = System.cmd("ps", ["-eo", "pid,%cpu,%mem,vsz,rss,user,lstart,command", "-ww"])

    output
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.filter(&String.contains?(&1, "hydra_srt_pipeline"))
    |> Enum.map(&parse_process_darwin/1)
  end

  defp list_pipeline_processes_detailed_darwin do
    {output, 0} =
      System.cmd("ps", [
        "-eo",
        "pid,%cpu,%mem,vsz,rss,time,state,ppid,user,lstart,command",
        "-ww"
      ])

    output
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.filter(&String.contains?(&1, "hydra_srt_pipeline"))
    |> Enum.map(&parse_process_detailed_darwin/1)
  end

  @spec process_layout(:darwin | :linux, :standard | :detailed) :: map()
  def process_layout(platform, detail) when platform in [:darwin, :linux] do
    @platform_process_layouts[platform][detail]
  end

  @spec parse_process(binary(), map()) :: map()
  def parse_process(line, layout) when is_binary(line) and is_map(layout) do
    fields = parse_process_fields(line, layout)

    %{
      pid: fields[:pid],
      cpu: fields[:cpu],
      memory: format_memory(fields[:memory_bytes]),
      memory_percent: fields[:memory_percent],
      memory_bytes: fields[:memory_bytes],
      swap_percent: fields[:swap_percent],
      swap_bytes: fields[:swap_bytes],
      user: fields[:user],
      start_time: fields[:start_time],
      command: fields[:command]
    }
  end

  @spec parse_process_detailed(binary(), map()) :: map()
  def parse_process_detailed(line, layout) when is_binary(line) and is_map(layout) do
    fields = parse_process_fields(line, layout)

    %{
      pid: fields[:pid],
      cpu: fields[:cpu],
      memory_percent: fields[:memory_percent],
      memory_bytes: fields[:memory_bytes],
      virtual_memory: fields[:virtual_memory],
      resident_memory: fields[:resident_memory],
      swap_percent: fields[:swap_percent],
      swap_bytes: fields[:swap_bytes],
      cpu_time: fields[:cpu_time],
      state: fields[:state],
      ppid: fields[:ppid],
      user: fields[:user],
      start_time: fields[:start_time],
      command: fields[:command]
    }
  end

  @spec parse_process_fields(binary(), map()) :: map()
  def parse_process_fields(line, layout) when is_binary(line) and is_map(layout) do
    parts = String.split(line, " ", trim: true)
    vsz = field_at(parts, layout[:vsz]) |> String.to_integer()
    rss = field_at(parts, layout[:rss]) |> String.to_integer()
    memory_bytes = rss * 1024
    swap_bytes = max(0, (vsz - rss) * 1024)

    swap_percent =
      if vsz > 0, do: "#{Float.round(swap_bytes / (1024 * 1024 * 1024) * 100, 1)}%", else: "0.0%"

    {start_time, command} = split_lstart_and_command(parts, layout[:lstart])

    %{
      pid: field_at(parts, layout[:pid]) |> String.to_integer(),
      cpu: field_at(parts, layout[:cpu]) <> "%",
      memory_percent: field_at(parts, layout[:memory_percent]) <> "%",
      memory_bytes: memory_bytes,
      virtual_memory: format_memory(vsz * 1024),
      resident_memory: format_memory(memory_bytes),
      swap_percent: swap_percent,
      swap_bytes: swap_bytes,
      cpu_time: field_at(parts, layout[:cpu_time]),
      state: field_at(parts, layout[:state]),
      ppid: parse_optional_integer(field_at(parts, layout[:ppid])),
      user: field_at(parts, layout[:user]),
      start_time: start_time,
      command: command
    }
  end

  @spec field_at([String.t()], non_neg_integer() | nil) :: String.t() | nil
  def field_at(parts, index) when is_list(parts) and is_integer(index), do: Enum.at(parts, index)
  def field_at(_parts, nil), do: nil

  @spec parse_optional_integer(String.t() | nil) :: non_neg_integer() | nil
  def parse_optional_integer(value) when is_binary(value), do: String.to_integer(value)
  def parse_optional_integer(nil), do: nil

  @spec parse_process_darwin(String.t()) :: map()
  defp parse_process_darwin(line), do: parse_process(line, process_layout(:darwin, :standard))

  @spec parse_process_detailed_darwin(String.t()) :: map()
  defp parse_process_detailed_darwin(line),
    do: parse_process_detailed(line, process_layout(:darwin, :detailed))

  defp list_pipeline_processes_linux do
    {output, 0} =
      System.cmd("ps", ["-eo", "pid,%cpu,%mem,vsz,rss,user,lstart,cmd", "--sort=-%cpu"])

    output
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.filter(&String.contains?(&1, "hydra_srt_pipeline"))
    |> Enum.map(&parse_process_linux/1)
  end

  defp list_pipeline_processes_detailed_linux do
    {output, 0} =
      System.cmd("ps", [
        "-eo",
        "pid,%cpu,%mem,vsz,rss,time,s,ppid,user,lstart,cmd",
        "--sort=-%cpu"
      ])

    output
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.filter(&String.contains?(&1, "hydra_srt_pipeline"))
    |> Enum.map(&parse_process_detailed_linux/1)
  end

  @spec parse_process_linux(String.t()) :: map()
  defp parse_process_linux(line), do: parse_process(line, process_layout(:linux, :standard))

  @spec parse_process_detailed_linux(String.t()) :: map()
  defp parse_process_detailed_linux(line),
    do: parse_process_detailed(line, process_layout(:linux, :detailed))

  defp format_memory(bytes) when is_integer(bytes) do
    cond do
      bytes > 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes > 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes > 1_024 -> "#{Float.round(bytes / 1_024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp split_lstart_and_command(parts, lstart_index) when is_list(parts) do
    start_time =
      parts
      |> Enum.slice(lstart_index, 5)
      |> Enum.join(" ")

    command =
      parts
      |> Enum.drop(lstart_index + 5)
      |> Enum.join(" ")

    {start_time, command}
  end
end

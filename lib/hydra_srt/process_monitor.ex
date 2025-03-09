defmodule HydraSrt.ProcessMonitor do
  @moduledoc false

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

  defp parse_process_darwin(line) do
    parts = line |> String.split(" ", trim: true)

    pid = Enum.at(parts, 0) |> String.to_integer()
    cpu = Enum.at(parts, 1) <> "%"
    memory_percent = Enum.at(parts, 2) <> "%"
    vsz = Enum.at(parts, 3) |> String.to_integer()
    rss = Enum.at(parts, 4) |> String.to_integer()
    user = Enum.at(parts, 5)

    memory_bytes = rss * 1024
    swap_bytes = max(0, (vsz - rss) * 1024)

    swap_percent =
      if vsz > 0, do: "#{Float.round(swap_bytes / (1024 * 1024 * 1024) * 100, 1)}%", else: "0.0%"

    start_time_parts = Enum.slice(parts, 6..11)
    start_time = Enum.join(start_time_parts, " ")

    command_parts = Enum.slice(parts, 12..(length(parts) - 1))
    command = Enum.join(command_parts, " ")

    %{
      pid: pid,
      cpu: cpu,
      memory: format_memory(memory_bytes),
      memory_percent: memory_percent,
      memory_bytes: memory_bytes,
      swap_percent: swap_percent,
      swap_bytes: swap_bytes,
      user: user,
      start_time: start_time,
      command: command
    }
  end

  defp parse_process_detailed_darwin(line) do
    parts = line |> String.split(" ", trim: true)

    pid = Enum.at(parts, 0) |> String.to_integer()
    cpu = Enum.at(parts, 1) <> "%"
    memory_percent = Enum.at(parts, 2) <> "%"
    vsz = Enum.at(parts, 3) |> String.to_integer()
    rss = Enum.at(parts, 4) |> String.to_integer()

    memory_bytes = rss * 1024
    swap_bytes = max(0, (vsz - rss) * 1024)

    swap_percent =
      if vsz > 0, do: "#{Float.round(swap_bytes / (1024 * 1024 * 1024) * 100, 1)}%", else: "0.0%"

    virtual_memory = format_memory(vsz * 1024)
    resident_memory = format_memory(memory_bytes)

    cpu_time = Enum.at(parts, 5)
    state = Enum.at(parts, 6)
    ppid = Enum.at(parts, 7) |> String.to_integer()
    user = Enum.at(parts, 8)

    start_time_parts = Enum.slice(parts, 9..14)
    start_time = Enum.join(start_time_parts, " ")

    command_parts = Enum.slice(parts, 15..(length(parts) - 1))
    command = Enum.join(command_parts, " ")

    %{
      pid: pid,
      cpu: cpu,
      memory_percent: memory_percent,
      memory_bytes: memory_bytes,
      virtual_memory: virtual_memory,
      resident_memory: resident_memory,
      swap_percent: swap_percent,
      swap_bytes: swap_bytes,
      cpu_time: cpu_time,
      state: state,
      ppid: ppid,
      user: user,
      start_time: start_time,
      command: command
    }
  end

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

  defp parse_process_linux(line) do
    parts = line |> String.split(" ", trim: true)

    pid = Enum.at(parts, 0) |> String.to_integer()
    cpu = Enum.at(parts, 1) <> "%"
    memory_percent = Enum.at(parts, 2) <> "%"
    vsz = Enum.at(parts, 3) |> String.to_integer()
    rss = Enum.at(parts, 4) |> String.to_integer()
    user = Enum.at(parts, 5)

    memory_bytes = rss * 1024
    swap_bytes = max(0, (vsz - rss) * 1024)

    swap_percent =
      if vsz > 0, do: "#{Float.round(swap_bytes / (1024 * 1024 * 1024) * 100, 1)}%", else: "0.0%"

    start_time_parts = Enum.slice(parts, 6..11)
    start_time = Enum.join(start_time_parts, " ")

    command_parts = Enum.slice(parts, 12..(length(parts) - 1))
    command = Enum.join(command_parts, " ")

    %{
      pid: pid,
      cpu: cpu,
      memory: format_memory(memory_bytes),
      memory_percent: memory_percent,
      memory_bytes: memory_bytes,
      swap_percent: swap_percent,
      swap_bytes: swap_bytes,
      user: user,
      start_time: start_time,
      command: command
    }
  end

  defp parse_process_detailed_linux(line) do
    parts = line |> String.split(" ", trim: true)

    pid = Enum.at(parts, 0) |> String.to_integer()
    cpu = Enum.at(parts, 1) <> "%"
    memory_percent = Enum.at(parts, 2) <> "%"
    vsz = Enum.at(parts, 3) |> String.to_integer()
    rss = Enum.at(parts, 4) |> String.to_integer()

    memory_bytes = rss * 1024
    swap_bytes = max(0, (vsz - rss) * 1024)

    swap_percent =
      if vsz > 0, do: "#{Float.round(swap_bytes / (1024 * 1024 * 1024) * 100, 1)}%", else: "0.0%"

    virtual_memory = format_memory(vsz * 1024)
    resident_memory = format_memory(memory_bytes)

    cpu_time = Enum.at(parts, 5)
    state = Enum.at(parts, 6)
    ppid = Enum.at(parts, 7) |> String.to_integer()
    user = Enum.at(parts, 8)

    start_time_parts = Enum.slice(parts, 9..14)
    start_time = Enum.join(start_time_parts, " ")

    command_parts = Enum.slice(parts, 15..(length(parts) - 1))
    command = Enum.join(command_parts, " ")

    %{
      pid: pid,
      cpu: cpu,
      memory_percent: memory_percent,
      memory_bytes: memory_bytes,
      virtual_memory: virtual_memory,
      resident_memory: resident_memory,
      swap_percent: swap_percent,
      swap_bytes: swap_bytes,
      cpu_time: cpu_time,
      state: state,
      ppid: ppid,
      user: user,
      start_time: start_time,
      command: command
    }
  end

  defp format_memory(bytes) when is_integer(bytes) do
    cond do
      bytes > 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes > 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes > 1_024 -> "#{Float.round(bytes / 1_024, 2)} KB"
      true -> "#{bytes} B"
    end
  end
end

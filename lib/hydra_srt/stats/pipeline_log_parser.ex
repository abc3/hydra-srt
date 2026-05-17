defmodule HydraSrt.Stats.PipelineLogParser do
  @moduledoc false

  @levels ~w(ERROR WARN INFO DEBUG FIXME LOG TRACE)

  @line_regex ~r/^(\d+:\d+:\d+\.\d+)\s+(\d+)\s+(0x[0-9a-fA-F]+)\s+(#{Enum.join(@levels, "|")})\s+(\S+)\s+([^:]+):(\d+):([^:<\s]+):?(?:<([^>]+)>)?\s+(.+)$/s

  @spec parse(binary()) :: {:ok, map()} | :error
  def parse(line) when is_binary(line) do
    case Regex.run(@line_regex, String.trim(line)) do
      [_, gst_ts, pid, thread_id, level, category, file, lineno, function, element, message] ->
        {:ok,
         %{
           gst_ts: gst_ts,
           pid: parse_int(pid),
           thread_id: thread_id,
           level: level,
           category: category,
           file: file,
           line: parse_int(lineno),
           function: function,
           element: if(element == "", do: nil, else: element),
           message: String.trim(message)
         }}

      _ ->
        :error
    end
  end

  defp parse_int(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end
end

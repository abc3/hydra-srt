defmodule HydraSrt.Metrics do
  @moduledoc """
  Helper functions for working with metrics.
  """

  require Logger

  alias HydraSrt.Metrics.Connection

  @measurement "hydra_srt_routes_stats"
  @metrics_error_log_interval_ms 10_000
  @metrics_error_log_key {__MODULE__, :last_metrics_error_log_ms}

  def event(k, v, tags \\ %{}, ts \\ System.system_time()) do
    # Logger.debug("Event: #{k} #{inspect(v)}")

    event_fields(%{k => v}, tags, ts)
  end

  def event_fields(fields, tags \\ %{}, ts \\ System.system_time()) when is_map(fields) do
    if map_size(fields) == 0 do
      :ok
    else
      try do
        Connection.write(%{
          measurement: @measurement,
          fields: fields,
          tags: tags,
          timestamp: ts
        })
      rescue
        error ->
          log_metrics_write_error(error, %{tags: tags, fields_count: map_size(fields)})
          {:error, error}
      catch
        kind, reason ->
          log_metrics_write_error({kind, reason}, %{tags: tags, fields_count: map_size(fields)})
          {:error, {kind, reason}}
      end
    end
  end

  @doc false
  def log_metrics_write_error(error, context \\ %{}) do
    now = System.monotonic_time(:millisecond)

    last =
      try do
        :persistent_term.get(@metrics_error_log_key, 0)
      rescue
        _ -> 0
      end

    if now - last >= @metrics_error_log_interval_ms do
      try do
        :persistent_term.put(@metrics_error_log_key, now)
      rescue
        _ -> :ok
      end

      Logger.error(
        "Metrics write failed (check VICTORIOMETRICS_HOST/VICTORIOMETRICS_PORT): #{inspect(error)} context=#{inspect(context)}"
      )
    end

    :ok
  end
end

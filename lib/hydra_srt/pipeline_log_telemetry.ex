defmodule HydraSrt.PipelineLogTelemetry do
  @moduledoc false

  @stored_event [:hydra, :pipeline, :log_line]
  @dropped_event [:hydra, :pipeline, :log_line, :dropped]
  @unparsed_event [:hydra, :pipeline, :log_line, :unparsed]

  def stored_event, do: @stored_event
  def dropped_event, do: @dropped_event
  def unparsed_event, do: @unparsed_event

  @spec emit_stored(binary(), binary()) :: :ok
  def emit_stored(route_id, level) when is_binary(route_id) and is_binary(level) do
    :telemetry.execute(@stored_event, %{count: 1}, %{route_id: route_id, level: level})
    :ok
  end

  @spec emit_dropped(binary(), binary()) :: :ok
  def emit_dropped(route_id, level) when is_binary(route_id) and is_binary(level) do
    :telemetry.execute(@dropped_event, %{count: 1}, %{route_id: route_id, level: level})
    :ok
  end

  @spec emit_unparsed(binary()) :: :ok
  def emit_unparsed(route_id) when is_binary(route_id) do
    :telemetry.execute(@unparsed_event, %{count: 1}, %{route_id: route_id})
    :ok
  end
end

defmodule HydraSrt.Metrics do
  @moduledoc """
  Helper functions for working with metrics.
  """

  require Logger

  alias HydraSrt.Metrics.Connection

  def event(k, v, tags \\ %{}, ts \\ System.system_time()) do
    # Logger.debug("Event: #{k} #{inspect(v)}")

    Connection.write(%{
      measurement: "hydra_srt_routes_stats",
      fields: %{k => v},
      tags: tags,
      timestamp: ts
    })
  end
end

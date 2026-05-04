defmodule HydraSrt.PromEx do
  @moduledoc false

  use PromEx, otp_app: :hydra_srt

  alias HydraSrt.PromEx.Plugins.OsMon
  alias PromEx.Plugins

  @impl true
  def plugins do
    poll_rate = Application.get_env(:hydra_srt, :prom_poll_rate, 15_000)

    [
      Plugins.Application,
      Plugins.Beam,
      {Plugins.Phoenix, router: HydraSrtWeb.Router, endpoint: HydraSrtWeb.Endpoint},
      {Plugins.Ecto, repos: [HydraSrt.Repo]},
      {OsMon, poll_rate: poll_rate}
    ]
  end

  def get_metrics do
    PromEx.get_metrics(__MODULE__)
  end
end

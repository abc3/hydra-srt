defmodule HydraSrt.Repo do
  use Ecto.Repo,
    otp_app: :hydra_srt,
    adapter: Ecto.Adapters.SQLite3
end

defmodule HydraSrtWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :hydra_srt

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_hydra_srt_key",
    signing_salt: "J9DwMByU",
    same_site: "Lax"
  ]

  socket "/socket", HydraSrtWeb.UserSocket,
    websocket: [
      connect_info: [:user_agent],
      check_origin: false
    ],
    longpoll: false

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug Plug.Static,
    at: "/",
    from: :hydra_srt,
    gzip: false,
    only: HydraSrtWeb.static_paths(),
    index: "index.html"

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :hydra_srt
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options

  plug CORSPlug,
    origin: ["*"],
    methods: ["*"],
    headers: ["*"],
    credentials: true,
    max_age: 86400

  plug HydraSrtWeb.Router
end

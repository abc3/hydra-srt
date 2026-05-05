defmodule HydraSrtWeb.Router do
  use HydraSrtWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_no_parse do
    plug :accepts, ["*/*"]
    plug :check_auth
  end

  pipeline :auth do
    plug :check_auth
  end

  scope "/health", HydraSrtWeb do
    get "/", HealthController, :index
  end

  scope "/metrics", HydraSrtWeb do
    get "/", MetricsController, :index
  end

  scope "/api", HydraSrtWeb do
    pipe_through :api

    post "/login", AuthController, :login
  end

  scope "/api", HydraSrtWeb do
    pipe_through [:api, :auth]
    post "/routes/test-source", RouteController, :test_source
    get "/tags", RouteController, :list_tags
    resources "/routes", RouteController, except: [:new, :edit]
    get "/routes/:route_id/analytics", RouteController, :analytics
    get "/routes/:route_id/events", RouteController, :events
    get "/routes/:route_id/start", RouteController, :start
    get "/routes/:route_id/stop", RouteController, :stop
    get "/routes/:route_id/restart", RouteController, :restart
    post "/routes/:id/switch-source", RouteController, :switch_source
    get "/routes/:route_id/destinations", DestinationController, :index
    post "/routes/:route_id/destinations", DestinationController, :create
    get "/routes/:route_id/destinations/:dest_id", DestinationController, :show
    put "/routes/:route_id/destinations/:dest_id", DestinationController, :update
    delete "/routes/:route_id/destinations/:dest_id", DestinationController, :delete
    get "/routes/:route_id/sources", SourceController, :index
    post "/routes/:route_id/sources", SourceController, :create
    get "/routes/:route_id/sources/:id", SourceController, :show
    patch "/routes/:route_id/sources/:id", SourceController, :update
    delete "/routes/:route_id/sources/:id", SourceController, :delete
    post "/routes/:route_id/sources-reorder", SourceController, :reorder
    post "/routes/:route_id/sources/reorder", SourceController, :reorder
    post "/routes/:route_id/sources/:id/test", SourceController, :test
    get "/interfaces/system", InterfaceController, :system
    get "/interfaces/system/raw", InterfaceController, :system_raw
    resources "/interfaces", InterfaceController, except: [:new, :edit]

    get "/backup/export", BackupController, :export
    get "/backup/create-download-link", BackupController, :create_download_link
    get "/backup/create-backup-download-link", BackupController, :create_backup_download_link

    get "/system/pipelines", SystemController, :list_pipelines
    get "/system/pipelines/detailed", SystemController, :list_pipelines_detailed
    post "/system/pipelines/:pid/kill", SystemController, :kill_pipeline

    get "/nodes", NodeController, :index
    get "/nodes/:id", NodeController, :show
  end

  # TODO: improve this
  scope "/api", HydraSrtWeb do
    pipe_through [:api_no_parse]
    post "/restore", BackupController, :restore
  end

  scope "/backup", HydraSrtWeb do
    get "/:session_id/download", BackupController, :download
    get "/:session_id/download_backup", BackupController, :download_backup
  end

  scope "/", HydraSrtWeb do
    pipe_through(:browser)

    get "/", PageController, :index
    get "/*path", PageController, :index
  end

  defp check_auth(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        if HydraSrt.Auth.authenticate_session(token) do
          conn
        else
          conn
          |> put_status(403)
          |> Phoenix.Controller.json(%{error: "Unauthorized"})
          |> halt()
        end

      _ ->
        conn
        |> put_status(403)
        |> Phoenix.Controller.json(%{error: "Authorization header missing"})
        |> halt()
    end
  end
end

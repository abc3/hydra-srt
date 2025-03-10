defmodule HydraSrtWeb.Router do
  use HydraSrtWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :auth do
    plug :check_auth
  end

  scope "/health", HydraSrtWeb do
    get "/", HealthController, :index
  end

  scope "/api", HydraSrtWeb do
    pipe_through :api

    post "/login", AuthController, :login
  end

  scope "/api", HydraSrtWeb do
    pipe_through [:api, :auth]
    resources "/routes", RouteController, except: [:new, :edit]
    get "/routes/:route_id/start", RouteController, :start
    get "/routes/:route_id/stop", RouteController, :stop
    get "/routes/:route_id/restart", RouteController, :restart
    get "/routes/:route_id/destinations", DestinationController, :index
    post "/routes/:route_id/destinations", DestinationController, :create
    get "/routes/:route_id/destinations/:dest_id", DestinationController, :show
    put "/routes/:route_id/destinations/:dest_id", DestinationController, :update
    delete "/routes/:route_id/destinations/:dest_id", DestinationController, :delete

    get "/system/pipelines", SystemController, :list_pipelines
    get "/system/pipelines/detailed", SystemController, :list_pipelines_detailed
    post "/system/pipelines/:pid/kill", SystemController, :kill_pipeline

    get "/nodes", NodeController, :index
    get "/nodes/:id", NodeController, :show
  end

  scope "/", HydraSrtWeb do
    pipe_through(:browser)

    get "/", PageController, :index
    get "/*path", PageController, :index
  end

  defp check_auth(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case Cachex.get(HydraSrt.Cache, "auth_session:#{token}") do
          {:ok, nil} ->
            conn
            |> put_status(403)
            |> Phoenix.Controller.json(%{error: "Unauthorized"})
            |> halt()

          {:ok, _value} ->
            conn

          _ ->
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

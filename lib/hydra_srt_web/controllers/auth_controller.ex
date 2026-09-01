defmodule HydraSrtWeb.AuthController do
  use HydraSrtWeb, :controller

  require Logger

  @spec login(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def login(conn, %{"login" => %{"user" => user, "password" => password}}) do
    # Authentication requires a proper mechanism before this endpoint is production-ready.
    configured_username = Application.get_env(:hydra_srt, :api_auth_username)
    configured_password = Application.get_env(:hydra_srt, :api_auth_password)

    cond do
      not credentials_configured?(configured_username, configured_password) ->
        Logger.error(
          "API authentication is not configured on this node, rejecting sign-in from #{client_ip(conn)}"
        )

        render_error(conn, :unauthorized, "INVALID_CREDENTIALS", "Invalid username or password")

      credentials_match?(user, configured_username, password, configured_password) ->
        token = generate_token()
        {:ok, _session} = HydraSrt.Auth.create_session(token, user)

        conn
        |> put_status(:ok)
        |> json(%{token: token, user: user})

      true ->
        Logger.warning(
          "Failed sign-in attempt for username #{inspect(user)} from #{client_ip(conn)}"
        )

        render_error(conn, :unauthorized, "INVALID_CREDENTIALS", "Invalid username or password")
    end
  end

  def login(conn, _params) do
    render_error(conn, :bad_request, "INVALID_REQUEST", "Invalid request format")
  end

  # Missing credentials must never authenticate: an empty configured value would
  # otherwise match an empty submitted one.
  @spec credentials_configured?(term(), term()) :: boolean()
  def credentials_configured?(username, password) do
    is_binary(username) and username != "" and is_binary(password) and password != ""
  end

  @spec credentials_match?(term(), term(), term(), term()) :: boolean()
  def credentials_match?(user, configured_username, password, configured_password)
      when is_binary(user) and is_binary(configured_username) and is_binary(password) and
             is_binary(configured_password) do
    username_matches = Plug.Crypto.secure_compare(user, configured_username)
    password_matches = Plug.Crypto.secure_compare(password, configured_password)

    username_matches and password_matches
  end

  def credentials_match?(_user, _configured_username, _password, _configured_password), do: false

  @spec client_ip(Plug.Conn.t()) :: String.t()
  def client_ip(conn) do
    conn.remote_ip
    |> :inet.ntoa()
    |> to_string()
  end

  @spec render_error(Plug.Conn.t(), atom(), String.t(), String.t()) :: Plug.Conn.t()
  def render_error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  @spec generate_token() :: String.t()
  def generate_token do
    :crypto.strong_rand_bytes(30)
    |> Base.url_encode64(padding: false)
  end
end

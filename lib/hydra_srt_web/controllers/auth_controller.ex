defmodule HydraSrtWeb.AuthController do
  use HydraSrtWeb, :controller

  def login(conn, %{"login" => %{"user" => user, "password" => password}}) do
    # TODO: Implement a proper authentication mechanism
    if user == Application.get_env(:hydra_srt, :api_auth_username) &&
         password == Application.get_env(:hydra_srt, :api_auth_password) do
      token = generate_token()

      Cachex.put(HydraSrt.Cache, "auth_session:#{token}", user, ttl: :timer.hours(24 * 14))

      conn
      |> put_status(:ok)
      |> json(%{token: token, user: user})
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Invalid username or password"})
    end
  end

  def login(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Invalid request format"})
  end

  defp generate_token do
    :crypto.strong_rand_bytes(30)
    |> Base.url_encode64(padding: false)
  end
end

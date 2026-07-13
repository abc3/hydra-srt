defmodule HydraSrt.Stats.VictoriaHttp do
  @moduledoc false

  @default_timeout 5_000

  @spec post(binary(), iodata(), [{binary(), binary()}], keyword()) ::
          {:ok, binary()} | {:error, term()}
  def post(url, body, headers \\ [], opts \\ []) when is_binary(url) do
    request(:post, url, body, headers, opts)
  end

  @spec post_form(binary(), map() | keyword(), keyword()) :: {:ok, binary()} | {:error, term()}
  def post_form(url, params, opts \\ []) when is_binary(url) do
    body = URI.encode_query(params)

    request(
      :post,
      url,
      body,
      [{"content-type", "application/x-www-form-urlencoded"}],
      opts
    )
  end

  @spec get(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def get(url, opts \\ []) when is_binary(url) do
    request(:get, url, "", [], opts)
  end

  @spec request(atom(), binary(), iodata(), [{binary(), binary()}], keyword()) ::
          {:ok, binary()} | {:error, term()}
  def request(method, url, body, headers, opts)
      when method in [:get, :post] and is_binary(url) and is_list(headers) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    request_opts = [
      recv_timeout: timeout,
      connect_timeout: timeout,
      follow_redirect: false
    ]

    case :hackney.request(method, url, headers, body, request_opts) do
      {:ok, status, _headers, client_ref} when status >= 200 and status < 300 ->
        case :hackney.body(client_ref) do
          {:ok, response_body} -> {:ok, response_body}
          {:error, reason} -> {:error, reason}
        end

      {:ok, status, _headers, client_ref} ->
        response_body =
          case :hackney.body(client_ref) do
            {:ok, value} -> value
            {:error, reason} -> inspect(reason)
          end

        {:error, {:http_status, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

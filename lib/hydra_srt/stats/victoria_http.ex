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

    # `with_body: true` makes hackney return the response body in place of a
    # client reference. hackney 4.x dropped the ability to hand a already-read
    # body back to `:hackney.body/1`, and this asks for the body up front
    # instead of streaming it, so there is no reference left to read.
    request_opts = [
      recv_timeout: timeout,
      connect_timeout: timeout,
      follow_redirect: false,
      with_body: true
    ]

    case :hackney.request(method, url, headers, body, request_opts) do
      {:ok, status, _headers, response_body} when status >= 200 and status < 300 ->
        {:ok, response_body}

      {:ok, status, _headers, response_body} ->
        {:error, {:http_status, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

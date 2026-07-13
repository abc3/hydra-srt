defmodule HydraSrt.Stats.VictoriaHttpTest do
  use ExUnit.Case, async: false

  alias HydraSrt.Stats.VictoriaHttp

  def url(port, path \\ "/") do
    "http://127.0.0.1:#{port}#{path}"
  end

  def start_stub_server(handler) do
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(lsock)

    task =
      Task.async(fn ->
        case :gen_tcp.accept(lsock, 5_000) do
          {:ok, sock} ->
            :ok = :inet.setopts(sock, packet: :http_bin, active: false)
            handler.(sock)

          {:error, _} ->
            :ok
        end

        :gen_tcp.close(lsock)
      end)

    {port, task}
  end

  def read_http_request(sock) do
    read_http_request(sock, %{method: nil, path: nil, headers: %{}, body: ""})
  end

  def read_http_request(sock, request) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, {:http_request, method, uri, _version}} ->
        request
        |> Map.put(:method, method)
        |> Map.put(:path, http_uri_path(uri))
        |> then(&read_http_request(sock, &1))

      {:ok, {:http_header, _field, _name_atom, header_name, value}} ->
        header_name = header_name |> to_string() |> String.downcase()

        request
        |> update_in([:headers], &Map.put(&1, header_name, to_string(value)))
        |> then(&read_http_request(sock, &1))

      {:ok, {:http_header, name, _reserved, value}} ->
        header_name = name |> to_string() |> String.downcase()

        request
        |> update_in([:headers], &Map.put(&1, header_name, to_string(value)))
        |> then(&read_http_request(sock, &1))

      {:ok, :http_eoh} ->
        content_length =
          request.headers
          |> Map.get("content-length", "0")
          |> String.to_integer()

        :ok = :inet.setopts(sock, packet: :raw)

        body = read_http_body(sock, content_length, "")
        Map.put(request, :body, body)

      {:error, reason} ->
        raise "failed to read HTTP request: #{inspect(reason)}"
    end
  end

  def http_uri_path({:abs_path, path}), do: IO.chardata_to_string(path)

  def http_uri_path({:absoluteURI, _scheme, _host, _port, path}),
    do: IO.chardata_to_string(path)

  def http_uri_path(path) when is_list(path), do: IO.chardata_to_string(path)
  def http_uri_path(path) when is_binary(path), do: path

  def read_http_body(_sock, 0, body), do: body

  def read_http_body(sock, remaining, body) when remaining > 0 do
    case :gen_tcp.recv(sock, remaining, 5_000) do
      {:ok, data} ->
        read_http_body(sock, remaining - byte_size(data), body <> data)

      {:error, reason} ->
        raise "failed to read HTTP body: #{inspect(reason)}"
    end
  end

  def send_http_response(sock, status, body) do
    status_line =
      case status do
        200 -> "HTTP/1.1 200 OK"
        204 -> "HTTP/1.1 204 No Content"
        500 -> "HTTP/1.1 500 Internal Server Error"
        other -> "HTTP/1.1 #{other}"
      end

    response =
      status_line <>
        "\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body

    :ok = :gen_tcp.send(sock, response)
    :gen_tcp.close(sock)
  end

  def respond_once(status, body) do
    start_stub_server(fn sock ->
      _request = read_http_request(sock)
      send_http_response(sock, status, body)
    end)
  end

  test "get returns body on 200 JSON response" do
    body = ~s({"status":"success","data":{"result":[]}})
    {port, task} = respond_once(200, body)
    endpoint = url(port, "/api/v1/query_range")

    assert {:ok, ^body} = VictoriaHttp.get(endpoint)
    Task.await(task, 5_000)
  end

  test "post returns empty body on 204 success" do
    {port, task} =
      start_stub_server(fn sock ->
        _request = read_http_request(sock)
        send_http_response(sock, 204, "")
      end)

    endpoint = url(port, "/api/v1/import/prometheus")

    assert {:ok, ""} =
             VictoriaHttp.post(
               endpoint,
               "hydra_srt_stats_sample 1\n",
               [{"content-type", "text/plain"}]
             )

    Task.await(task, 5_000)
  end

  test "request returns http_status error tuple on 500" do
    error_body = "internal error"
    {port, task} = respond_once(500, error_body)
    endpoint = url(port, "/select/logsql/query")

    assert {:error, {:http_status, 500, ^error_body}} =
             VictoriaHttp.request(
               :post,
               endpoint,
               "query=up",
               [
                 {"content-type", "application/x-www-form-urlencoded"}
               ],
               []
             )

    Task.await(task, 5_000)
  end

  test "get returns econnrefused when service is unreachable" do
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(lsock)
    :gen_tcp.close(lsock)
    endpoint = "http://127.0.0.1:#{port}/"

    assert {:error, :econnrefused} = VictoriaHttp.get(endpoint)
  end

  test "get returns timeout when server responds slower than recv timeout" do
    {port, task} =
      start_stub_server(fn sock ->
        _request = read_http_request(sock)
        Process.sleep(200)
        :gen_tcp.close(sock)
      end)

    endpoint = url(port, "/slow")

    assert {:error, :timeout} = VictoriaHttp.get(endpoint, timeout: 50)
    Task.await(task, 5_000)
  end

  test "get returns raw body without JSON decoding" do
    malformed = "not{json"
    {port, task} = respond_once(200, malformed)
    endpoint = url(port, "/api/v1/query_range")

    assert {:ok, ^malformed} = VictoriaHttp.get(endpoint)
    Task.await(task, 5_000)
  end

  test "post_form encodes params as application/x-www-form-urlencoded body" do
    params = %{
      "query" => ~s(metric{route_id="route\"one"}),
      "start" => "1704067200",
      "end" => "1704070800",
      "step" => "30"
    }

    expected_body = URI.encode_query(params)

    {port, task} =
      start_stub_server(fn sock ->
        request = read_http_request(sock)

        assert request.body == expected_body
        assert request.headers["content-type"] == "application/x-www-form-urlencoded"

        send_http_response(sock, 200, ~s({"status":"success"}))
      end)

    endpoint = url(port, "/api/v1/query_range")

    assert {:ok, _body} = VictoriaHttp.post_form(endpoint, params)
    Task.await(task, 5_000)
  end
end

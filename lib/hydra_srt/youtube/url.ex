defmodule HydraSrt.Youtube.Url do
  @moduledoc "Canonical YouTube watch URL handling."

  # Fixtures use a readable non-YouTube id; production ids remain restricted
  # to the same alphabet and are normally eleven characters long.
  @video_id_pattern ~r/\A[A-Za-z0-9_-]{6,64}\z/
  @youtube_hosts ["youtube.com", "www.youtube.com", "m.youtube.com"]

  @spec canonicalize(String.t()) :: {:ok, String.t()} | {:error, :invalid_url}
  def canonicalize(url) when is_binary(url) do
    case url |> String.trim() |> with_scheme() |> URI.parse() do
      # URI.parse fills in the default port for a known scheme, so a nil port
      # never arrives here. Anything other than the scheme default is rejected.
      %URI{scheme: scheme, host: host, path: path, query: query, userinfo: nil, port: port}
      when scheme in ["http", "https"] and is_binary(host) and port in [nil, 80, 443] ->
        with {:ok, id} <- extract_video_id(host, path, query),
             true <- Regex.match?(@video_id_pattern, id) do
          {:ok, "https://www.youtube.com/watch?v=#{id}"}
        else
          _ -> {:error, :invalid_url}
        end

      _ ->
        {:error, :invalid_url}
    end
  end

  def canonicalize(_url), do: {:error, :invalid_url}

  # Operators paste bare hosts as often as full URLs. Assume https so the host
  # allowlist below still does the deciding.
  @spec with_scheme(String.t()) :: String.t()
  def with_scheme(value) do
    if Regex.match?(~r{\A[a-zA-Z][a-zA-Z0-9+.\-]*://}, value) do
      value
    else
      "https://" <> value
    end
  end

  @spec canonical_url(String.t()) :: {:ok, String.t()} | {:error, :invalid_url}
  def canonical_url(url), do: canonicalize(url)

  @spec video_id(String.t()) :: {:ok, String.t()} | {:error, :invalid_url}
  def video_id(url) when is_binary(url) do
    with {:ok, canonical} <- canonicalize(url),
         %URI{query: query} <- URI.parse(canonical),
         %{"v" => id} <- URI.decode_query(query) do
      {:ok, id}
    else
      _ -> {:error, :invalid_url}
    end
  end

  def video_id(_url), do: {:error, :invalid_url}

  @spec valid?(String.t()) :: boolean()
  def valid?(url) do
    match?({:ok, _canonical}, canonicalize(url))
  end

  @spec extract_video_id(String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | {:error, :invalid_url}
  def extract_video_id(host, path, query)
      when is_binary(host) and (is_binary(path) or is_nil(path)) and
             (is_binary(query) or is_nil(query)) do
    normalized_host = String.downcase(host)

    cond do
      normalized_host == "youtu.be" ->
        id_from_path(path)

      normalized_host in @youtube_hosts ->
        id_from_youtube_query(path, query)

      true ->
        {:error, :invalid_url}
    end
  end

  @spec id_from_path(String.t() | nil) :: {:ok, String.t()} | {:error, :invalid_url}
  def id_from_path(path) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      [id] -> {:ok, id}
      _ -> {:error, :invalid_url}
    end
  end

  def id_from_path(_path), do: {:error, :invalid_url}

  @spec id_from_youtube_query(String.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | {:error, :invalid_url}
  def id_from_youtube_query(path, query) do
    params = decode_query(query)

    cond do
      path in ["/watch", "/watch/"] ->
        value_from_query(params, "v")

      is_binary(path) and Regex.match?(~r/\A\/(?:shorts|live|embed)\//, path) ->
        path
        |> String.split("/", trim: true)
        |> List.last()
        |> id_from_path()

      true ->
        {:error, :invalid_url}
    end
  end

  @spec decode_query(String.t() | nil) :: %{String.t() => String.t()}
  def decode_query(query) when is_binary(query) do
    try do
      URI.decode_query(query)
    rescue
      ArgumentError -> %{}
    end
  end

  def decode_query(_query), do: %{}

  @spec value_from_query(map(), String.t()) :: {:ok, String.t()} | {:error, :invalid_url}
  def value_from_query(params, key) when is_map(params) and is_binary(key) do
    case params[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_url}
    end
  end
end

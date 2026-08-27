defmodule HydraSrt.TestSupport.HlsServer do
  @moduledoc "Small controllable HTTP server for local HLS fixtures."

  @type behavior ::
          :normal
          | :segments_403
          | :segments_410
          | :playlist_404
          | :discontinuous
          | %{mode: :stall, delay_ms: pos_integer(), target: :all | :playlist | :segments}

  @type handle :: %{
          pid: pid(),
          control: pid(),
          ref: term(),
          port: pos_integer(),
          root: String.t(),
          url: String.t()
        }

  @spec start(String.t(), keyword()) :: {:ok, handle()} | {:error, term()}
  def start(root, opts \\ []) when is_binary(root) and is_list(opts) do
    with {:ok, _apps} <- Application.ensure_all_started(:plug_cowboy),
         {:ok, control} <- Agent.start_link(fn -> :normal end),
         {:ok, port} <- free_port() do
      ref = {:hydra_hls_server, System.unique_integer([:positive])}

      case Plug.Cowboy.http(__MODULE__.Plug, [root: root, control: control],
             port: port,
             ref: ref
           ) do
        {:ok, pid} ->
          Process.link(pid)

          handle = %{
            pid: pid,
            control: control,
            ref: ref,
            port: port,
            root: root,
            url: "http://127.0.0.1:#{port}"
          }

          wait_for_listener(port, System.monotonic_time(:millisecond) + 5_000)
          {:ok, handle}

        error ->
          Agent.stop(control)
          error
      end
    end
  end

  @spec stop(handle()) :: :ok
  def stop(%{pid: pid, ref: ref, control: control}) do
    Process.unlink(pid)
    _ = Plug.Cowboy.shutdown(ref)

    if Process.alive?(control) do
      try do
        Agent.stop(control, :normal)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  @spec set_behavior(handle(), behavior()) :: :ok
  def set_behavior(%{control: control}, behavior) do
    true =
      behavior in [:normal, :segments_403, :segments_410, :playlist_404, :discontinuous] or
        is_map(behavior)

    Agent.update(control, fn _ -> behavior end)
  end

  @spec behavior(handle()) :: behavior()
  def behavior(%{control: control}), do: Agent.get(control, & &1)

  @spec url(handle(), String.t()) :: String.t()
  def url(%{url: base}, path) when is_binary(path) do
    base <> "/" <> String.trim_leading(path, "/")
  end

  @spec playlist_url(handle()) :: String.t()
  def playlist_url(handle), do: url(handle, "playlist.m3u8")

  @spec free_port() :: {:ok, pos_integer()} | {:error, term()}
  def free_port do
    case :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true]) do
      {:ok, socket} ->
        result = :inet.sockname(socket)
        :gen_tcp.close(socket)

        case result do
          {:ok, {_ip, port}} -> {:ok, port}
          error -> error
        end

      error ->
        error
    end
  end

  @spec wait_for_listener(pos_integer(), integer()) :: :ok
  def wait_for_listener(port, deadline_ms) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 100) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        if System.monotonic_time(:millisecond) < deadline_ms do
          receive do
          after
            25 -> wait_for_listener(port, deadline_ms)
          end
        else
          raise "HLS fixture server did not start: #{inspect(reason)}"
        end
    end
  end

  defmodule Plug do
    @moduledoc "Serves the generated HLS directory and injects the failure modes tests ask for."

    @spec init(keyword()) :: keyword()
    def init(opts), do: opts

    @spec call(Elixir.Plug.Conn.t(), keyword()) :: Elixir.Plug.Conn.t()
    def call(conn, opts) do
      root = opts[:root]
      control = opts[:control]
      relative = conn.request_path |> URI.decode() |> String.trim_leading("/")
      behavior = Agent.get(control, & &1)

      cond do
        unsafe_path?(relative) ->
          Elixir.Plug.Conn.send_resp(conn, 404, "not found")

        status = forced_status(relative, behavior) ->
          Elixir.Plug.Conn.send_resp(conn, status, "fixture response")

        stall? = stall_target(behavior, relative) ->
          stall(stall?, relative, root, conn, behavior)

        true ->
          send_file(relative, root, conn, behavior)
      end
    end

    @spec unsafe_path?(String.t()) :: boolean()
    def unsafe_path?(relative) do
      relative == "" or Enum.any?(String.split(relative, "/"), &(&1 in ["..", "."]))
    end

    @spec forced_status(String.t(), HydraSrt.TestSupport.HlsServer.behavior()) ::
            nil | pos_integer()
    def forced_status(relative, :segments_403) do
      if segment?(relative), do: 403
    end

    @spec forced_status(String.t(), HydraSrt.TestSupport.HlsServer.behavior()) ::
            nil | pos_integer()
    def forced_status(relative, :segments_410) do
      if segment?(relative), do: 410
    end

    @spec forced_status(
            relative :: String.t(),
            behavior :: HydraSrt.TestSupport.HlsServer.behavior()
          ) :: nil | pos_integer()
    def forced_status(relative, :playlist_404) do
      if playlist?(relative), do: 404
    end

    @spec forced_status(String.t(), HydraSrt.TestSupport.HlsServer.behavior()) ::
            nil | pos_integer()
    def forced_status(_relative, _behavior), do: nil

    @spec stall_target(HydraSrt.TestSupport.HlsServer.behavior(), String.t()) ::
            false | pos_integer()
    def stall_target(%{mode: :stall, delay_ms: delay_ms, target: target}, relative)
        when is_integer(delay_ms) and delay_ms > 0 do
      if target == :all or (target == :playlist and playlist?(relative)) or
           (target == :segments and segment?(relative)) do
        delay_ms
      else
        false
      end
    end

    @spec stall_target(HydraSrt.TestSupport.HlsServer.behavior(), String.t()) :: false
    def stall_target(_behavior, _relative), do: false

    @spec stall(
            pos_integer(),
            String.t(),
            String.t(),
            Elixir.Plug.Conn.t(),
            HydraSrt.TestSupport.HlsServer.behavior()
          ) :: Elixir.Plug.Conn.t()
    def stall(delay_ms, relative, root, conn, behavior) do
      Process.sleep(delay_ms)
      send_file(relative, root, conn, behavior)
    end

    @spec send_file(
            String.t(),
            String.t(),
            Elixir.Plug.Conn.t(),
            HydraSrt.TestSupport.HlsServer.behavior()
          ) :: Elixir.Plug.Conn.t()
    def send_file(relative, root, conn, behavior) do
      path = Path.join(root, relative)

      case File.read(path) do
        {:ok, body} ->
          if playlist?(relative) do
            body = rewrite_playlist(body, behavior)

            Elixir.Plug.Conn.put_resp_content_type(conn, "application/vnd.apple.mpegurl")
            |> Elixir.Plug.Conn.send_resp(200, body)
          else
            Elixir.Plug.Conn.put_resp_content_type(conn, "video/mp2t")
            |> Elixir.Plug.Conn.send_resp(200, body)
          end

        {:error, _reason} ->
          Elixir.Plug.Conn.send_resp(conn, 404, "not found")
      end
    end

    @spec rewrite_playlist(String.t(), HydraSrt.TestSupport.HlsServer.behavior()) :: String.t()
    def rewrite_playlist(body, behavior) do
      body = Regex.replace(~r/^#EXT-X-VERSION:\d+$/m, body, "#EXT-X-VERSION:3")
      body = Regex.replace(~r/^#EXT-X-TARGETDURATION:\d+$/m, body, "#EXT-X-TARGETDURATION:5")

      if behavior == :discontinuous do
        lines = String.split(body, "\n")

        {lines, _inserted} =
          Enum.map_reduce(lines, false, fn line, inserted ->
            if not inserted and String.ends_with?(line, ".ts") do
              {["#EXT-X-DISCONTINUITY", line], true}
            else
              {line, inserted}
            end
          end)

        List.flatten(lines) |> Enum.join("\n")
      else
        body
      end
    end

    @spec playlist?(String.t()) :: boolean()
    def playlist?(relative), do: String.ends_with?(relative, ".m3u8")

    @spec segment?(String.t()) :: boolean()
    def segment?(relative), do: String.ends_with?(relative, ".ts")
  end
end

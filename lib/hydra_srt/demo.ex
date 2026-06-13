defmodule HydraSrt.Demo do
  @moduledoc false

  alias HydraSrt.Api
  alias HydraSrt.Repo
  alias HydraSrt.Api.Route

  @demo_route_name "demo_route"
  @demo_udp_route_name "demo_udp_route"
  @demo_rtp_route_name "demo_rtp_route"
  @demo_rtmp_route_name "demo_rtmp_route"
  @demo_rtmp_client_route_name "demo_rtmp-client_route"
  @demo_source_name "demo_source"
  @demo_udp_source_name "demo_udp_source"
  @demo_rtp_source_name "demo_rtp_source"
  @demo_rtmp_source_name "demo_rtmp_source"
  @demo_srt_destination_name "demo_srt_destination"
  @demo_udp_destination_name "demo_udp_destination"
  @demo_udp_srt_destination_name "demo_udp_srt_destination"
  @demo_udp_udp_destination_name "demo_udp_udp_destination"
  @demo_rtp_srt_destination_name "demo_rtp_srt_destination"
  @demo_rtp_udp_destination_name "demo_rtp_udp_destination"
  @demo_rtmp_srt_destination_name "demo_rtmp_srt_destination"
  @demo_rtmp_destination_name "demo_rtmp_destination"
  @demo_rtmp_destination_location "rtmp://127.0.0.1:1935/live/stream"
  @demo_rtmp_client_udp_port 4216

  @spec ensure_requirements!(boolean()) :: :ok
  def ensure_requirements!(false), do: :ok

  def ensure_requirements!(true) do
    case System.find_executable("ffmpeg") do
      nil ->
        raise """
        DEMO_DATA=true requires ffmpeg to be installed and available in PATH.
        Install ffmpeg and restart HydraSRT.
        """

      _path ->
        :ok
    end
  end

  @spec bootstrap(boolean()) :: :ok
  def bootstrap(false), do: :ok

  def bootstrap(true) do
    route = ensure_demo_route!()
    _source = ensure_demo_source!(route.id)
    _srt_dest = ensure_demo_srt_destination!(route.id)
    _udp_dest = ensure_demo_udp_destination!(route.id)

    udp_route = ensure_demo_udp_route!()
    _udp_source = ensure_demo_udp_source!(udp_route.id)
    _udp_srt_dest = ensure_demo_udp_srt_destination!(udp_route.id)
    _udp_udp_dest = ensure_demo_udp_udp_destination!(udp_route.id)

    rtp_route = ensure_demo_rtp_route!()
    _rtp_source = ensure_demo_rtp_source!(rtp_route.id)
    _rtp_srt_dest = ensure_demo_rtp_srt_destination!(rtp_route.id)
    _rtp_udp_dest = ensure_demo_rtp_udp_destination!(rtp_route.id)

    rtmp_route = ensure_demo_rtmp_route!()
    _rtmp_source = ensure_demo_rtmp_source!(rtmp_route.id)
    _rtmp_srt_dest = ensure_demo_rtmp_srt_destination!(rtmp_route.id)

    rtmp_client_route = ensure_demo_rtmp_client_route!()
    _rtmp_client_source = ensure_demo_source!(rtmp_client_route.id)
    _rtmp_client_udp_dest = ensure_demo_rtmp_client_udp_destination!(rtmp_client_route.id)
    _rtmp_client_rtmp_dest = ensure_demo_rtmp_destination!(rtmp_client_route.id)

    :ok
  end

  defp ensure_demo_route! do
    case find_route_by_name(@demo_route_name) do
      %{} = route ->
        route

      nil ->
        {:ok, route} =
          Api.create_route(%{
            name: @demo_route_name,
            enabled: false
          })

        route
    end
  end

  defp ensure_demo_udp_route! do
    case find_route_by_name(@demo_udp_route_name) do
      %{} = route ->
        route

      nil ->
        {:ok, route} =
          Api.create_route(%{
            name: @demo_udp_route_name,
            enabled: false
          })

        route
    end
  end

  defp ensure_demo_rtp_route! do
    case find_route_by_name(@demo_rtp_route_name) do
      %{} = route ->
        route

      nil ->
        {:ok, route} =
          Api.create_route(%{
            name: @demo_rtp_route_name,
            enabled: false
          })

        route
    end
  end

  defp ensure_demo_rtmp_route! do
    case find_route_by_name(@demo_rtmp_route_name) do
      %{} = route ->
        route

      nil ->
        {:ok, route} =
          Api.create_route(%{
            name: @demo_rtmp_route_name,
            enabled: false
          })

        route
    end
  end

  defp ensure_demo_rtmp_client_route! do
    case find_route_by_name(@demo_rtmp_client_route_name) do
      %{} = route ->
        route

      nil ->
        {:ok, route} =
          Api.create_route(%{
            name: @demo_rtmp_client_route_name,
            enabled: false
          })

        route
    end
  end

  defp ensure_demo_source!(route_id) do
    case find_source_by_name(route_id, @demo_source_name) do
      %{} = source ->
        if source.schema == "UDP" do
          {:ok, updated} =
            Api.update_source(source, %{
              schema: "SRT",
              mode: "caller",
              host: "127.0.0.1",
              port: 4200
            })

          updated
        else
          source
        end

      nil ->
        create_source!(route_id, %{
          name: @demo_source_name,
          schema: "SRT",
          mode: "caller",
          host: "127.0.0.1",
          port: 4200,
          enabled: true,
          position: 0
        })
    end
  end

  defp ensure_demo_udp_source!(route_id) do
    case find_source_by_name(route_id, @demo_udp_source_name) do
      %{} = source ->
        maybe_update_endpoint!(source, %{schema: "UDP", address: "127.0.0.1", port: 4201})

      nil ->
        create_source!(route_id, %{
          name: @demo_udp_source_name,
          schema: "UDP",
          address: "127.0.0.1",
          port: 4201,
          enabled: true,
          position: 0
        })
    end
  end

  defp ensure_demo_rtp_source!(route_id) do
    case find_source_by_name(route_id, @demo_rtp_source_name) do
      %{} = source ->
        maybe_update_endpoint!(source, %{schema: "RTP", address: "127.0.0.1", port: 4202})

      nil ->
        create_source!(route_id, %{
          name: @demo_rtp_source_name,
          schema: "RTP",
          address: "127.0.0.1",
          port: 4202,
          enabled: true,
          position: 0
        })
    end
  end

  defp ensure_demo_rtmp_source!(route_id) do
    case find_source_by_name(route_id, @demo_rtmp_source_name) do
      %{} = source ->
        maybe_update_endpoint!(source, %{schema: "RTMP", path: "/live/test"})

      nil ->
        create_source!(route_id, %{
          name: @demo_rtmp_source_name,
          schema: "RTMP",
          path: "/live/test",
          enabled: true,
          position: 0
        })
    end
  end

  defp ensure_demo_srt_destination!(route_id) do
    case find_destination_by_name(route_id, @demo_srt_destination_name) do
      %{} = destination ->
        maybe_update_endpoint!(destination, %{
          schema: "SRT",
          mode: "listener",
          localaddress: "127.0.0.1",
          localport: 4211
        })

      nil ->
        create_destination!(route_id, %{
          name: @demo_srt_destination_name,
          schema: "SRT",
          mode: "listener",
          localaddress: "127.0.0.1",
          localport: 4211,
          enabled: true
        })
    end
  end

  defp ensure_demo_udp_destination!(route_id) do
    case find_destination_by_name(route_id, @demo_udp_destination_name) do
      %{} = destination ->
        maybe_update_endpoint!(destination, %{schema: "UDP", host: "0.0.0.0", port: 4212})

      nil ->
        create_destination!(route_id, %{
          name: @demo_udp_destination_name,
          schema: "UDP",
          host: "0.0.0.0",
          port: 4212,
          enabled: true
        })
    end
  end

  defp ensure_demo_rtmp_client_udp_destination!(route_id) do
    case find_destination_by_name(route_id, @demo_udp_destination_name) do
      %{} = destination ->
        maybe_update_endpoint!(destination, %{
          schema: "UDP",
          host: "127.0.0.1",
          port: @demo_rtmp_client_udp_port
        })

      nil ->
        create_destination!(route_id, %{
          name: @demo_udp_destination_name,
          schema: "UDP",
          host: "127.0.0.1",
          port: @demo_rtmp_client_udp_port,
          enabled: true
        })
    end
  end

  defp ensure_demo_udp_srt_destination!(route_id) do
    case find_destination_by_name(route_id, @demo_udp_srt_destination_name) do
      %{} = destination ->
        maybe_update_endpoint!(destination, %{
          schema: "SRT",
          mode: "listener",
          localaddress: "127.0.0.1",
          localport: 4213
        })

      nil ->
        create_destination!(route_id, %{
          name: @demo_udp_srt_destination_name,
          schema: "SRT",
          mode: "listener",
          localaddress: "127.0.0.1",
          localport: 4213,
          enabled: true
        })
    end
  end

  defp ensure_demo_udp_udp_destination!(route_id) do
    case find_destination_by_name(route_id, @demo_udp_udp_destination_name) do
      %{} = destination ->
        maybe_update_endpoint!(destination, %{schema: "UDP", host: "0.0.0.0", port: 4214})

      nil ->
        create_destination!(route_id, %{
          name: @demo_udp_udp_destination_name,
          schema: "UDP",
          host: "0.0.0.0",
          port: 4214,
          enabled: true
        })
    end
  end

  defp ensure_demo_rtp_srt_destination!(route_id) do
    find_destination_by_name(route_id, @demo_rtp_srt_destination_name) ||
      create_destination!(route_id, %{
        name: @demo_rtp_srt_destination_name,
        schema: "SRT",
        mode: "listener",
        localaddress: "127.0.0.1",
        localport: 4205,
        enabled: true
      })
  end

  defp ensure_demo_rtp_udp_destination!(route_id) do
    find_destination_by_name(route_id, @demo_rtp_udp_destination_name) ||
      create_destination!(route_id, %{
        name: @demo_rtp_udp_destination_name,
        schema: "UDP",
        host: "0.0.0.0",
        port: 4206,
        enabled: true
      })
  end

  defp ensure_demo_rtmp_srt_destination!(route_id) do
    case find_destination_by_name(route_id, @demo_rtmp_srt_destination_name) do
      %{} = destination ->
        maybe_update_endpoint!(destination, %{
          schema: "SRT",
          mode: "listener",
          localaddress: "127.0.0.1",
          localport: 4215
        })

      nil ->
        create_destination!(route_id, %{
          name: @demo_rtmp_srt_destination_name,
          schema: "SRT",
          mode: "listener",
          localaddress: "127.0.0.1",
          localport: 4215,
          enabled: true
        })
    end
  end

  defp ensure_demo_rtmp_destination!(route_id) do
    case find_destination_by_name(route_id, @demo_rtmp_destination_name) do
      %{} = destination ->
        maybe_update_endpoint!(destination, %{
          schema: "RTMP",
          location: @demo_rtmp_destination_location
        })

      nil ->
        create_destination!(route_id, %{
          name: @demo_rtmp_destination_name,
          schema: "RTMP",
          location: @demo_rtmp_destination_location,
          enabled: true
        })
    end
  end

  defp maybe_update_endpoint!(endpoint, expected_attrs) do
    updates =
      Enum.reduce(expected_attrs, %{}, fn {key, expected}, acc ->
        if Map.get(endpoint, key) != expected do
          Map.put(acc, key, expected)
        else
          acc
        end
      end)

    if map_size(updates) == 0 do
      endpoint
    else
      case endpoint.type do
        "source" ->
          {:ok, updated} = Api.update_source(endpoint, updates)
          updated

        "destination" ->
          {:ok, updated} = Api.update_destination(endpoint, updates)
          updated
      end
    end
  end

  defp create_source!(route_id, attrs) do
    {:ok, source} = Api.create_source(route_id, attrs)
    source
  end

  defp create_destination!(route_id, attrs) do
    {:ok, destination} = Api.create_destination(route_id, attrs)
    destination
  end

  defp find_route_by_name(name) do
    Repo.get_by(Route, name: name)
  end

  defp find_source_by_name(route_id, name) do
    Api.list_sources(route_id)
    |> Enum.find(&(&1.name == name))
  end

  defp find_destination_by_name(route_id, name) do
    Api.list_destinations(route_id)
    |> Enum.find(&(&1.name == name))
  end
end

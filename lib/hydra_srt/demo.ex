defmodule HydraSrt.Demo do
  @moduledoc false

  alias HydraSrt.Api
  alias HydraSrt.Repo
  alias HydraSrt.Api.Route

  @demo_route_name "demo_route"
  @demo_source_name "demo_source"
  @demo_srt_destination_name "demo_srt_destination"
  @demo_udp_destination_name "demo_udp_destination"

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

  defp ensure_demo_source!(route_id) do
    find_source_by_name(route_id, @demo_source_name) ||
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

  defp ensure_demo_srt_destination!(route_id) do
    find_destination_by_name(route_id, @demo_srt_destination_name) ||
      create_destination!(route_id, %{
        name: @demo_srt_destination_name,
        schema: "SRT",
        mode: "listener",
        localaddress: "127.0.0.1",
        localport: 4201,
        enabled: true
      })
  end

  defp ensure_demo_udp_destination!(route_id) do
    find_destination_by_name(route_id, @demo_udp_destination_name) ||
      create_destination!(route_id, %{
        name: @demo_udp_destination_name,
        schema: "UDP",
        host: "0.0.0.0",
        port: 4202,
        enabled: true
      })
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

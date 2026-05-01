defmodule HydraSrt.Api do
  @moduledoc """
  The Api context.
  """

  import Ecto.Query, warn: false
  alias HydraSrt.Repo

  alias HydraSrt.Api.Route
  alias HydraSrt.Api.Destination
  alias HydraSrt.Api.Source

  @doc false
  def list_routes(with_destinations) when with_destinations in [true, false] do
    _ = with_destinations
    Repo.all(Route)
  end

  @doc false
  def get_route(id, with_destinations \\ false)
      when is_binary(id) and with_destinations in [true, false] do
    _ = with_destinations
    Repo.get(Route, id)
  end

  @doc false
  def list_destinations(route_id) when is_binary(route_id) do
    from(d in Destination, where: d.route_id == ^route_id)
    |> Repo.all()
  end

  @doc false
  def get_destination(route_id, destination_id)
      when is_binary(route_id) and is_binary(destination_id) do
    from(d in Destination, where: d.id == ^destination_id and d.route_id == ^route_id)
    |> Repo.one()
  end

  @doc false
  def list_sources(route_id) when is_binary(route_id) do
    from(s in Source, where: s.route_id == ^route_id, order_by: [asc: s.position])
    |> Repo.all()
  end

  @doc false
  def get_source(route_id, source_id)
      when is_binary(route_id) and is_binary(source_id) do
    from(s in Source, where: s.id == ^source_id and s.route_id == ^route_id)
    |> Repo.one()
  end

  @doc false
  def get_source(source_id) when is_binary(source_id) do
    Repo.get(Source, source_id)
  end

  @doc false
  def create_source(route_id, attrs) when is_binary(route_id) and is_map(attrs) do
    attrs
    |> Map.put_new(:route_id, route_id)
    |> Map.put_new("route_id", route_id)
    |> create_source()
  end

  @doc false
  def create_destination(route_id, attrs) when is_binary(route_id) and is_map(attrs) do
    attrs
    |> Map.put_new(:route_id, route_id)
    |> Map.put_new("route_id", route_id)
    |> create_destination()
  end

  @doc """
  Returns the list of routes.

  ## Examples

      iex> list_routes()
      [%Route{}, ...]

  """
  def list_routes do
    Repo.all(Route)
  end

  @doc """
  Gets a single route.

  Raises `Ecto.NoResultsError` if the Route does not exist.

  ## Examples

      iex> get_route!(123)
      %Route{}

      iex> get_route!(456)
      ** (Ecto.NoResultsError)

  """
  def get_route!(id), do: Repo.get!(Route, id)

  @doc """
  Creates a route.

  ## Examples

      iex> create_route(%{field: value})
      {:ok, %Route{}}

      iex> create_route(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_route(attrs \\ %{}) do
    %Route{}
    |> Route.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a route.

  ## Examples

      iex> update_route(route, %{field: new_value})
      {:ok, %Route{}}

      iex> update_route(route, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_route(%Route{} = route, attrs) do
    route
    |> Route.changeset(attrs)
    |> Repo.update(stale_error_field: :lock_version)
  end

  @doc """
  Deletes a route.

  ## Examples

      iex> delete_route(route)
      {:ok, %Route{}}

      iex> delete_route(route)
      {:error, %Ecto.Changeset{}}

  """
  def delete_route(%Route{} = route) do
    Repo.delete(route)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking route changes.

  ## Examples

      iex> change_route(route)
      %Ecto.Changeset{data: %Route{}}

  """
  def change_route(%Route{} = route, attrs \\ %{}) do
    Route.changeset(route, attrs)
  end

  @doc """
  Returns the list of destinations.

  ## Examples

      iex> list_destinations()
      [%Destination{}, ...]

  """
  def list_destinations do
    Repo.all(Destination)
  end

  @doc """
  Gets a single destination.

  Raises `Ecto.NoResultsError` if the Destination does not exist.

  ## Examples

      iex> get_destination!(123)
      %Destination{}

      iex> get_destination!(456)
      ** (Ecto.NoResultsError)

  """
  def get_destination!(id), do: Repo.get!(Destination, id)

  @doc """
  Creates a destination.

  ## Examples

      iex> create_destination(%{field: value})
      {:ok, %Destination{}}

      iex> create_destination(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_destination(attrs \\ %{}) do
    %Destination{}
    |> Destination.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a destination.

  ## Examples

      iex> update_destination(destination, %{field: new_value})
      {:ok, %Destination{}}

      iex> update_destination(destination, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_destination(%Destination{} = destination, attrs) do
    destination
    |> Destination.changeset(attrs)
    |> Repo.update(stale_error_field: :lock_version)
  end

  @doc """
  Deletes a destination.

  ## Examples

      iex> delete_destination(destination)
      {:ok, %Destination{}}

      iex> delete_destination(destination)
      {:error, %Ecto.Changeset{}}

  """
  def delete_destination(%Destination{} = destination) do
    Repo.delete(destination)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking destination changes.

  ## Examples

      iex> change_destination(destination)
      %Ecto.Changeset{data: %Destination{}}

  """
  def change_destination(%Destination{} = destination, attrs \\ %{}) do
    Destination.changeset(destination, attrs)
  end

  @doc """
  Returns the list of sources.
  """
  def list_sources do
    Repo.all(Source)
  end

  @doc """
  Gets a single source.
  """
  def get_source!(id), do: Repo.get!(Source, id)

  @doc """
  Creates a source.
  """
  def create_source(attrs \\ %{}) do
    %Source{}
    |> Source.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a source.
  """
  def update_source(%Source{} = source, attrs) do
    source
    |> Source.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a source.
  """
  def delete_source(%Source{} = source) do
    Repo.delete(source)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking source changes.
  """
  def change_source(%Source{} = source, attrs \\ %{}) do
    Source.changeset(source, attrs)
  end

  alias HydraSrt.Api.Interface

  @doc """
  Returns the list of interfaces.

  ## Examples

      iex> list_interfaces()
      [%Interface{}, ...]

  """
  def list_interfaces do
    Repo.all(Interface)
  end

  @doc """
  Gets a single interface.

  Raises `Ecto.NoResultsError` if the Interface does not exist.

  ## Examples

      iex> get_interface!(123)
      %Interface{}

      iex> get_interface!(456)
      ** (Ecto.NoResultsError)

  """
  def get_interface!(id), do: Repo.get!(Interface, id)

  @doc """
  Creates a interface.

  ## Examples

      iex> create_interface(%{field: value})
      {:ok, %Interface{}}

      iex> create_interface(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_interface(attrs \\ %{}) do
    %Interface{}
    |> Interface.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a interface.

  ## Examples

      iex> update_interface(interface, %{field: new_value})
      {:ok, %Interface{}}

      iex> update_interface(interface, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_interface(%Interface{} = interface, attrs) do
    interface
    |> Interface.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a interface.

  ## Examples

      iex> delete_interface(interface)
      {:ok, %Interface{}}

      iex> delete_interface(interface)
      {:error, %Ecto.Changeset{}}

  """
  def delete_interface(%Interface{} = interface) do
    Repo.delete(interface)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking interface changes.

  ## Examples

      iex> change_interface(interface)
      %Ecto.Changeset{data: %Interface{}}

  """
  def change_interface(%Interface{} = interface, attrs \\ %{}) do
    Interface.changeset(interface, attrs)
  end
end

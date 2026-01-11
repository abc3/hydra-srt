defmodule HydraSrt.Api do
  @moduledoc """
  The Api context.
  """

  import Ecto.Query, warn: false
  alias HydraSrt.Repo

  alias HydraSrt.Api.Route
  alias HydraSrt.Api.Destination

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
end

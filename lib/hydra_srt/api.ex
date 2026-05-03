defmodule HydraSrt.Api do
  @moduledoc """
  The Api context.
  """

  import Ecto.Query, warn: false
  alias HydraSrt.Repo

  alias HydraSrt.Api.Route
  alias HydraSrt.Api.Endpoint

  @doc false
  def list_routes(with_destinations) when with_destinations in [true, false] do
    preloads = if with_destinations, do: [:sources, :destinations], else: [:sources]

    Route
    |> Repo.all()
    |> Repo.preload(preloads)
  end

  @doc false
  def get_route(id, with_destinations \\ false)
      when is_binary(id) and with_destinations in [true, false] do
    preloads = if with_destinations, do: [:sources, :destinations], else: [:sources]

    Route
    |> Repo.get(id)
    |> Repo.preload(preloads)
  end

  @doc false
  def list_destinations(route_id) when is_binary(route_id) do
    Endpoint.destination_scope()
    |> where([e], e.route_id == ^route_id)
    |> Repo.all()
  end

  @doc false
  def get_destination(route_id, destination_id)
      when is_binary(route_id) and is_binary(destination_id) do
    Endpoint.destination_scope()
    |> where([e], e.id == ^destination_id and e.route_id == ^route_id)
    |> Repo.one()
  end

  @doc false
  def list_sources(route_id) when is_binary(route_id) do
    Endpoint.source_scope()
    |> where([e], e.route_id == ^route_id)
    |> order_by([e], asc: e.position)
    |> Repo.all()
  end

  @doc false
  def get_source(route_id, source_id)
      when is_binary(route_id) and is_binary(source_id) do
    Endpoint.source_scope()
    |> where([e], e.id == ^source_id and e.route_id == ^route_id)
    |> Repo.one()
  end

  @doc false
  def get_source(source_id) when is_binary(source_id) do
    Endpoint.source_scope()
    |> where([e], e.id == ^source_id)
    |> Repo.one()
  end

  @doc false
  def create_source(route_id, attrs) when is_binary(route_id) and is_map(attrs) do
    attrs = normalize_endpoint_attrs(attrs)

    attrs
    |> Map.put_new(:route_id, route_id)
    |> create_source()
  end

  @doc false
  def create_destination(route_id, attrs) when is_binary(route_id) and is_map(attrs) do
    attrs = normalize_endpoint_attrs(attrs)

    attrs
    |> Map.put_new(:route_id, route_id)
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
      [%Endpoint{}, ...]

  """
  def list_destinations do
    Endpoint.destination_scope()
    |> Repo.all()
  end

  @doc """
  Gets a single destination.

  Raises `Ecto.NoResultsError` if the destination endpoint does not exist.

  ## Examples

      iex> get_destination!(123)
      %Endpoint{}

      iex> get_destination!(456)
      ** (Ecto.NoResultsError)

  """
  def get_destination!(id), do: Repo.get_by!(Endpoint, id: id, type: Endpoint.destination_type())

  @doc """
  Creates a destination.

  ## Examples

      iex> create_destination(%{field: value})
      {:ok, %Endpoint{}}

      iex> create_destination(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_destination(attrs \\ %{}) do
    attrs = normalize_endpoint_attrs(attrs)
    create_destination_with_position_retry(attrs, 3)
  end

  @doc """
  Updates a destination.

  ## Examples

      iex> update_destination(destination, %{field: new_value})
      {:ok, %Endpoint{}}

      iex> update_destination(destination, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_destination(%Endpoint{} = destination, attrs) do
    destination
    |> Endpoint.destination_changeset(attrs)
    |> Repo.update(stale_error_field: :lock_version)
  end

  @doc """
  Deletes a destination.

  ## Examples

      iex> delete_destination(destination)
      {:ok, %Endpoint{}}

      iex> delete_destination(destination)
      {:error, %Ecto.Changeset{}}

  """
  def delete_destination(%Endpoint{} = destination) do
    Repo.delete(destination)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking destination changes.

  ## Examples

      iex> change_destination(destination)
      %Ecto.Changeset{data: %Endpoint{}}

  """
  def change_destination(%Endpoint{} = destination, attrs \\ %{}) do
    Endpoint.destination_changeset(destination, attrs)
  end

  @doc """
  Returns the list of sources.
  """
  def list_sources do
    Endpoint.source_scope()
    |> Repo.all()
  end

  @doc """
  Gets a single source.
  """
  def get_source!(id), do: Repo.get_by!(Endpoint, id: id, type: Endpoint.source_type())

  @doc """
  Creates a source.
  """
  def create_source(attrs \\ %{}) do
    %Endpoint{}
    |> Endpoint.source_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a source.
  """
  def update_source(%Endpoint{} = source, attrs) do
    source
    |> Endpoint.source_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a source.
  """
  def delete_source(%Endpoint{} = source) do
    Repo.delete(source)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking source changes.
  """
  def change_source(%Endpoint{} = source, attrs \\ %{}) do
    Endpoint.source_changeset(source, attrs)
  end

  defp create_destination_with_position_retry(attrs, attempts_left)
       when is_map(attrs) and attempts_left > 0 do
    {attrs, auto_position?} = maybe_put_destination_position(attrs)

    case %Endpoint{}
         |> Endpoint.destination_changeset(attrs)
         |> Repo.insert() do
      {:ok, destination} ->
        {:ok, destination}

      {:error, %Ecto.Changeset{} = changeset} ->
        if auto_position? and unique_position_constraint_error?(changeset) and attempts_left > 1 do
          attrs =
            attrs
            |> Map.delete(:position)
            |> Map.delete("position")

          create_destination_with_position_retry(attrs, attempts_left - 1)
        else
          {:error, changeset}
        end
    end
  end

  defp maybe_put_destination_position(attrs) when is_map(attrs) do
    has_position? = Map.has_key?(attrs, :position)

    if has_position? do
      {attrs, false}
    else
      route_id = Map.get(attrs, :route_id)

      if is_binary(route_id) do
        next_position =
          Endpoint.destination_scope()
          |> where([e], e.route_id == ^route_id)
          |> select([e], max(e.position))
          |> Repo.one()
          |> case do
            nil -> 0
            n when is_integer(n) -> n + 1
          end

        {Map.put(attrs, :position, next_position), true}
      else
        {attrs, false}
      end
    end
  end

  defp unique_position_constraint_error?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_message, opts}} ->
        opts[:constraint] == :unique and
          to_string(opts[:constraint_name]) == "endpoints_route_id_position_type_index"
    end)
  end

  @endpoint_attr_keys [
    "route_id",
    "position",
    "enabled",
    "name",
    "alias",
    "status",
    "schema",
    "schema_options",
    "node",
    "started_at",
    "stopped_at",
    "last_probe_at",
    "last_failure_at",
    "lock_version"
  ]

  defp normalize_endpoint_attrs(attrs) when is_map(attrs) do
    Enum.reduce(@endpoint_attr_keys, attrs, fn key, acc ->
      atom_key = String.to_existing_atom(key)

      case Map.fetch(acc, key) do
        {:ok, value} -> acc |> Map.put_new(atom_key, value) |> Map.delete(key)
        :error -> acc
      end
    end)
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

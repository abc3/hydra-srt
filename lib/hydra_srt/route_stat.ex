defmodule HydraSrt.RouteStat do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "route_stats" do
    field :route_id, :string
    field :source_stream_id, :string
    field :stats, :map

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:route_id, :source_stream_id, :stats])
    |> validate_required([:route_id, :stats])
  end
end

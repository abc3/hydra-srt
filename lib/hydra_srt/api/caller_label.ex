defmodule HydraSrt.Api.CallerLabel do
  use Ecto.Schema
  import Ecto.Changeset

  alias HydraSrt.CallerLabels

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "caller_labels" do
    field :address, :string
    field :label, :string
    field :note, :string

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(caller_label, attrs) when is_map(attrs) do
    caller_label
    |> cast(attrs, [:address, :label, :note])
    |> validate_required([:address, :label])
    |> validate_change(:address, fn :address, address ->
      if CallerLabels.valid_address?(address),
        do: [],
        else: [address: "must be an IP address or CIDR range"]
    end)
    |> validate_change(:label, fn :label, label ->
      if is_binary(label) and String.trim(label) != "", do: [], else: [label: "must not be empty"]
    end)
    |> update_change(:address, &String.trim/1)
    |> update_change(:label, &String.trim/1)
    |> unique_constraint(:address)
  end
end

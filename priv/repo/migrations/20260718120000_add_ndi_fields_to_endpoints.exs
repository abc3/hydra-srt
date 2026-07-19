defmodule HydraSrt.Repo.Migrations.AddNdiFieldsToEndpoints do
  use Ecto.Migration

  def up do
    alter table(:endpoints) do
      add :ndi_source_name, :string
      add :ndi_source_address, :string
      add :ndi_selection_mode, :string
      add :ndi_observed_address_snapshot, :string
      add :ndi_observed_name_snapshot, :string
      add :ndi_selection_observed_at, :utc_datetime
      add :ndi_receiver_name, :string
      add :ndi_media_policy, :string
      add :ndi_bandwidth, :string
      add :ndi_color_format, :string
      add :ndi_timestamp_mode, :string
      add :ndi_connect_timeout_ms, :integer
      add :ndi_receive_timeout_ms, :integer
      add :ndi_track_discovery_timeout_ms, :integer
      add :ndi_max_queue_length, :integer
      add :ndi_sender_name, :string
      add :ndi_sender_name_key, :string
    end

    create unique_index(:endpoints, [:ndi_sender_name_key],
             name: :endpoints_ndi_sender_name_key_enabled_dest_index,
             where:
               "schema = 'NDI' AND type = 'destination' AND enabled = 1 AND ndi_sender_name_key IS NOT NULL"
           )
  end

  def down do
    drop_if_exists index(:endpoints, [:ndi_sender_name_key],
                     name: :endpoints_ndi_sender_name_key_enabled_dest_index
                   )

    alter table(:endpoints) do
      remove :ndi_source_name
      remove :ndi_source_address
      remove :ndi_selection_mode
      remove :ndi_observed_address_snapshot
      remove :ndi_observed_name_snapshot
      remove :ndi_selection_observed_at
      remove :ndi_receiver_name
      remove :ndi_media_policy
      remove :ndi_bandwidth
      remove :ndi_color_format
      remove :ndi_timestamp_mode
      remove :ndi_connect_timeout_ms
      remove :ndi_receive_timeout_ms
      remove :ndi_track_discovery_timeout_ms
      remove :ndi_max_queue_length
      remove :ndi_sender_name
      remove :ndi_sender_name_key
    end
  end
end

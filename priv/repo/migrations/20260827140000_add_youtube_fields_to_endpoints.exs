defmodule HydraSrt.Repo.Migrations.AddYoutubeFieldsToEndpoints do
  use Ecto.Migration

  def change do
    alter table(:endpoints) do
      add :youtube_url, :string
      add :youtube_format_id, :string
      add :youtube_quality_policy, :string
      add :youtube_live_mode, :boolean
      add :youtube_media_info, :map
      add :youtube_info_updated_at, :utc_datetime
      add :youtube_end_action, :string
    end
  end
end

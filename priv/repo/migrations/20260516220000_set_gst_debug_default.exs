defmodule HydraSrt.Repo.Migrations.SetGstDebugDefault do
  use Ecto.Migration

  def up do
    execute("UPDATE routes SET gst_debug = '4' WHERE gst_debug IS NULL OR gst_debug = ''")
  end

  def down do
    execute("UPDATE routes SET gst_debug = NULL WHERE gst_debug = '4'")
  end
end

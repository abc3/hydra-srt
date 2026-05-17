defmodule HydraSrt.Repo.Migrations.SetGstDebugDefault do
  use Ecto.Migration

  def up do
    execute("UPDATE routes SET gst_debug = '4' WHERE gst_debug IS NULL OR gst_debug = ''")
  end

  def down do
    # Intentionally irreversible: reverting would erase legitimate existing "4" values.
    :ok
  end
end

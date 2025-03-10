defmodule Mix.Tasks.CompileCApp do
  @moduledoc """
  Compiles the native C application.

  ## Examples

      $ mix compile_c_app

  """
  use Mix.Task

  @shortdoc "Compiles the native C application"
  def run(_) do
    IO.puts("Compiling C application...")
    {result, exit_code} = System.cmd("make", ["-C", "native"])
    IO.puts(result)

    if exit_code != 0 do
      Mix.raise("Failed to compile C application")
    end

    # Verify the binary was created
    binary_path = Path.join(["native", "build", "hydra_srt_pipeline"])

    unless File.exists?(binary_path) do
      Mix.raise("C application binary was not created at #{binary_path}")
    end

    IO.puts("C application compiled successfully at #{binary_path}")
  end
end

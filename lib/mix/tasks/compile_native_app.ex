defmodule Mix.Tasks.CompileNativeApp do
  @moduledoc """
  Compiles the native Rust application.

  ## Examples

      $ mix compile_native_app

  """
  use Mix.Task

  @shortdoc "Compiles the native Rust application"
  def run(_) do
    IO.puts("Compiling Rust native application...")
    {result, exit_code} = System.cmd("cargo", ["build"], cd: "rs-native")
    IO.puts(result)

    if exit_code != 0 do
      Mix.raise("Failed to compile Rust native application")
    end

    binary_path = Path.join(["rs-native", "target", "debug", "hydra_srt_pipeline"])

    unless File.exists?(binary_path) do
      Mix.raise("Rust native binary was not created at #{binary_path}")
    end

    IO.puts("Rust native application compiled successfully at #{binary_path}")
  end
end

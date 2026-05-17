defmodule Mix.Tasks.Credence do
  @moduledoc """
  Runs [Credence](https://hex.pm/packages/credence) semantic analysis on project sources.

      mix credence
      mix credence lib/hydra_srt

  Scans `lib/` and `test/` by default. Exits with status 1 when issues are found.
  """
  use Mix.Task

  @shortdoc "Run Credence semantic linter on project sources"

  @default_paths ["lib", "test"]
  @extensions [".ex", ".exs"]

  if Mix.env() in [:dev, :test] do
    def run(args) do
      Mix.Task.run("compile")

      paths = if args == [], do: @default_paths, else: args
      files = list_files(paths)

      issue_count =
        Enum.reduce(files, 0, fn path, count ->
          source = File.read!(path)
          %{issues: issues} = Credence.analyze(source)
          print_issues(path, issues)
          count + length(issues)
        end)

      Mix.shell().info("")
      Mix.shell().info("Credence: #{issue_count} issue(s) in #{length(files)} file(s)")

      if issue_count > 0 do
        System.halt(1)
      end
    end

    def list_files(paths) do
      paths
      |> Enum.flat_map(fn path ->
        if File.dir?(path) do
          Path.wildcard(Path.join(path, "**/*"))
        else
          [path]
        end
      end)
      |> Enum.filter(&String.ends_with?(&1, @extensions))
      |> Enum.uniq()
      |> Enum.sort()
    end

    def print_issues(_path, []), do: :ok

    def print_issues(path, issues) do
      Enum.each(issues, fn %{rule: rule, message: message} ->
        Mix.shell().error("#{path}: [#{rule}] #{message}")
      end)
    end
  else
    def run(_args) do
      Mix.raise(
        "mix credence is only available in :dev and :test (credence is not a prod dependency)"
      )
    end
  end
end

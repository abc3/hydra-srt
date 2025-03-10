defmodule HydraSrt.MixProject do
  use Mix.Project

  def project do
    [
      app: :hydra_srt,
      version: "0.1.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {HydraSrt.Application, []},
      extra_applications:
        [:logger, :os_mon, :ssl, :runtime_tools] ++ extra_applications(Mix.env())
    ]
  end

  defp extra_applications(:dev), do: [:wx, :observer]
  defp extra_applications(_), do: []

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.7.14"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.10"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:plug_cowboy, "~> 2.7"},
      {:khepri, "0.16.0"},
      {:uuid, "~> 1.1"},
      {:cors_plug, "~> 3.0"},
      {:syn, "~> 3.3"},
      {:cachex, "~> 3.6"},
      {:observer_cli, "~> 1.7"},
      {:meck, "~> 1.0", only: [:dev, :test], override: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:benchee, "~> 1.3", only: :dev},
      {:instream, "~> 2.0"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end

  defp releases do
    [
      hydra_srt: [
        steps: [:assemble, &copy_c_app/1, &copy_web_app/1],
        cookie: System.get_env("RELEASE_COOKIE", Base.url_encode64(:crypto.strong_rand_bytes(30)))
      ]
    ]
  end

  defp copy_c_app(release) do
    IO.puts("Copying C application to release...")

    {result, exit_code} = System.cmd("make", ["-C", "native"])
    IO.puts(result)

    if exit_code != 0 do
      raise "Failed to compile C application"
    end

    source_path = Path.join(["native", "build", "hydra_srt_pipeline"])

    unless File.exists?(source_path) do
      raise "C application binary was not created at #{source_path}"
    end

    dest_dir = Path.join([release.path, "native", "build"])
    File.mkdir_p!(dest_dir)

    dest_path = Path.join(dest_dir, "hydra_srt_pipeline")
    File.cp!(source_path, dest_path)
    File.chmod!(dest_path, 0o755)

    IO.puts("C application copied successfully to #{dest_path}")

    release
  end

  defp copy_web_app(release) do
    IO.puts("Building and copying web app to release...")

    web_app_dir = "web_app"
    IO.puts("Building web app with npm run build...")

    {build_result, build_exit_code} = System.cmd("npm", ["run", "build"], cd: web_app_dir)
    IO.puts(build_result)

    if build_exit_code != 0 do
      raise "Failed to build web app with npm run build"
    end

    web_app_source = Path.join([web_app_dir, "dist"])

    unless File.dir?(web_app_source) do
      raise "Web app dist directory not found at #{web_app_source} after build. Build may have failed."
    end

    app_dir = Path.join([release.path, "lib", "hydra_srt-#{release.version}"])
    web_app_dest = Path.join(app_dir, "priv/static")

    File.mkdir_p!(web_app_dest)

    web_app_source
    |> File.ls!()
    |> Enum.each(fn file ->
      source_file = Path.join(web_app_source, file)
      dest_file = Path.join(web_app_dest, file)

      if File.dir?(source_file) do
        File.cp_r!(source_file, dest_file)
      else
        File.cp!(source_file, dest_file)
      end
    end)

    IO.puts("Web app built and copied successfully to #{web_app_dest}")

    release
  end
end

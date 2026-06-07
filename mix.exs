defmodule HydraSrt.MixProject do
  use Mix.Project

  def project do
    [
      app: :hydra_srt,
      version: version(),
      compilers: [:rs_native] ++ Mix.compilers(),
      elixir: "~> 1.18",
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
  defp version, do: File.read!("./VERSION") |> String.trim()

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      # Phoenix
      {:phoenix, "~> 1.7.14"},
      {:phoenix_ecto, "~> 4.5"},
      {:plug_cowboy, "~> 2.7"},
      {:cors_plug, "~> 3.0"},

      # Database
      {:ecto_sql, "~> 3.10"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:adbc, "~> 0.1"},

      # Telemetry and observability
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:prom_ex, "~> 1.11"},
      {:peep, "~> 4.2", override: true},
      {:observer_cli, "~> 1.7"},

      # Runtime
      {:ex_rtmp, "~> 0.4.1"},
      {:ranch, "~> 2.0", override: true},
      {:syn, "~> 3.3"},
      {:cachex, "~> 3.6"},
      {:hermes_mcp, "~> 0.14.1"},

      # Notifications
      {:telegram, github: "visciang/telegram", ref: "6dca11fff18c41fafffb92bb82082350ff1df217"},
      {:hackney, "~> 1.18"},

      # Utilities
      {:jason, "~> 1.2"},
      {:uuid, "~> 1.1"},

      # Linting
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:credence, "~> 0.5.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false, warn_if_outdated: true},

      # Benchmarking
      {:benchee, "~> 1.3", only: :dev},

      # Test utilities
      {:meck, "~> 1.0", only: [:dev, :test], override: true}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  @sobelow_ignore_files [
    "config/dev.exs",
    "config/test.exs",
    "config/runtime.exs"
  ]

  defp sobelow_cmd do
    ignore_files = Enum.join(@sobelow_ignore_files, ",")

    "sobelow --no-config --exit Low --verbose --skip -i Config.HTTPS,Config.Headers --ignore-files #{ignore_files}"
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "compile.rs_native": &rs_native_build/1,
      credence: ["credence"],
      sobelow: [sobelow_cmd()],
      q: ["quality"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --min-priority higher",
        "sobelow",
        "dialyzer"
      ]
    ]
  end

  defp releases do
    [
      hydra_srt: [
        steps: [:assemble, &copy_web_app/1],
        cookie: System.get_env("RELEASE_COOKIE", Base.url_encode64(:crypto.strong_rand_bytes(30)))
      ]
    ]
  end

  defp rs_native_build(_args) do
    config = rs_native_build_config()

    Mix.shell().info("Building Rust native application (#{config.profile})...")
    File.mkdir_p!(config.dest_dir)

    exit_code =
      Mix.shell().cmd({"cargo", config.cargo_args},
        cd: config.rs_native_dir,
        stderr_to_stdout: true,
        env: [
          {"CARGO_TERM_COLOR", if(IO.ANSI.enabled?(), do: "always", else: "auto")}
        ]
      )

    if exit_code != 0 do
      Mix.raise("Failed to compile Rust native application", exit_status: exit_code)
    end

    unless File.exists?(config.source_path) do
      Mix.raise("Rust native binary was not found at #{config.source_path}")
    end

    File.cp!(config.source_path, config.dest_path)
    File.chmod!(config.dest_path, 0o755)

    Mix.shell().info("Rust native application copied to #{config.dest_path}")

    {:ok, []}
  end

  defp rs_native_build_config do
    profile = if Mix.env() == :prod, do: "release", else: "debug"
    project_root = project_root()
    rs_native_dir = Path.join(project_root, "native")
    priv_native_dir = Path.join(project_root, "priv/native")

    %{
      profile: profile,
      cargo_args: rs_native_cargo_args(profile),
      rs_native_dir: rs_native_dir,
      dest_dir: priv_native_dir,
      dest_path: Path.join(priv_native_dir, "hydra_srt_pipeline"),
      source_path: Path.join([rs_native_dir, "target", profile, "hydra_srt_pipeline"])
    }
  end

  defp rs_native_cargo_args("release"), do: ["build", "--release"]
  defp rs_native_cargo_args(_profile), do: ["build"]

  defp project_root do
    Path.expand(__DIR__)
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

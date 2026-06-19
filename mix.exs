defmodule BlauDrill.MixProject do
  use Mix.Project

  def project do
    [
      app: :blau_drill,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {BlauDrill.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Run the multi-step aliases that end in `test` under MIX_ENV=test, so the
  # whole alias (compile + test) shares the test environment.
  def cli do
    [preferred_envs: [ci: :test, precommit: :test]]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  #
  # NOTE: This is an ephemeral, single-session, single-operator machine-control
  # app. There is intentionally NO database — no Ecto, Repo, or DB driver.
  defp deps do
    [
      {:tidewave, "~> 0.6", only: [:dev]},
      # --- Phoenix / LiveView web stack ---
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      # Required by Phoenix.LiveViewTest for DOM assertions in tests.
      {:lazy_html, ">= 0.1.0", only: :test},

      # --- Web server (Bandit is the Phoenix 1.7+ default adapter) ---
      {:bandit, "~> 1.12"},

      # --- JSON & telemetry ---
      {:jason, "~> 1.4"},
      {:telemetry_metrics, "~> 1.1"},
      {:telemetry_poller, "~> 1.3"},

      # --- Asset pipeline (dev/build only) ---
      # `esbuild` provides the JS bundler binary; `tailwind` provides the CSS
      # binary. JS bundling itself is driven by the LiveSvelte build.js script
      # (esbuild-svelte), so esbuild is kept available but not wired as a watcher.
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},

      # --- Svelte <-> LiveView integration (Node build pipeline via build.js) ---
      {:live_svelte, "~> 0.15.0"},

      # --- Serial port for the (future) PrinterConnection GenServer ---
      {:circuits_uart, "~> 1.6"},

      # --- Property-based testing for safety-invariant tests (test/dev) ---
      {:stream_data, "~> 1.3", only: [:dev, :test]},

      # --- Codemod tooling: provides `mix igniter.install` and powers
      #     Tidewave's installer (which wires its plug into the endpoint). ---
      {:igniter, "~> 0.6", only: [:dev, :test]}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      # Install the esbuild + tailwind binaries, and the npm toolchain that
      # LiveSvelte's build.js needs (esbuild-svelte, svelte, etc.).
      "assets.setup": [
        "tailwind.install --if-missing",
        "esbuild.install --if-missing",
        "cmd --cd assets npm install"
      ],
      # Build CSS via tailwind and JS (incl. Svelte SSR + client) via build.js.
      "assets.build": [
        "tailwind blau_drill",
        "cmd --cd assets node build.js"
      ],
      "assets.deploy": [
        "tailwind blau_drill --minify",
        "cmd --cd assets node build.js --deploy",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      # Non-mutating CI gate: verify formatting, fail on any compile warning,
      # then run the suite — in that order, so a cheap check fails fast before
      # the expensive one. `format --check-formatted` only reports drift (it
      # does not rewrite files), which is what a CI gate wants.
      ci: [
        "format --check-formatted",
        "compile --warnings-as-errors --force",
        # Build the Svelte/JS assets: build.js fails on any esbuild or Svelte
        # warning (a11y, unused, etc.), so the gate catches frontend warnings too.
        "assets.build",
        "test"
      ]
    ]
  end
end

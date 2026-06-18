# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Configure the endpoint
config :blau_drill, BlauDrillWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BlauDrillWeb.ErrorHTML, json: BlauDrillWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: BlauDrill.PubSub,
  live_view: [signing_salt: "Yq8nB2pL"]

# Configure LiveSvelte rendering. Components hydrate on the client via the
# SvelteHook (assets/js/app.js). Server-side rendering is OFF by default: the
# SSR pipeline (assets/build.js -> priv/svelte/server.js, rendered through a
# NodeJS pool) is wired up in application.ex and config, but the
# esbuild-plugin-import-glob component registration needs to be reconciled with
# LiveSvelte 0.15's `normalizeComponents` before SSR pre-render produces markup.
# Flip to `ssr: true` (and rebuild assets) once that is resolved; the NodeJS
# supervisor will start automatically when SSR is enabled and the bundle exists.
config :live_svelte,
  ssr: false

# Configure esbuild (the version is required). NOTE: JS bundling is actually
# driven by assets/build.js (esbuild-svelte) so it can compile Svelte for both
# the client and the SSR target. This block keeps the esbuild binary available
# (e.g. `mix esbuild.install`) and documents the version we build against.
config :esbuild,
  version: "0.25.4"

# Configure tailwind (the version is required). Tailwind v4 reads its config
# from assets/css/app.css (CSS-first), where the Industrial Dark tokens live.
config :tailwind,
  version: "4.1.7",
  blau_drill: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Register the Excellon drill (.drl) and Gerber (.gbr) extensions as plain text
# so LiveView's `allow_upload` accept filter recognises them. They are text
# formats; this only lets the upload component validate the extension.
config :mime, :types, %{
  "text/plain" => ["drl", "gbr"]
}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

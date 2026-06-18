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

# Configure LiveSvelte rendering. Components are server-side rendered (SSR) for
# the initial dead-render and then hydrated on the client via the SvelteHook
# (assets/js/app.js). The SSR pipeline is: assets/build.js compiles
# assets/js/server.js -> priv/svelte/server.js (svelte `generate: "server"`),
# which the NodeJS pool (started conditionally in application.ex) invokes via
# {"server", "render"}; component.ex injects the returned head/html.
#
# SSR was previously OFF: under Svelte 5 (≥5.x) `render()` from `svelte/server`
# returns a RenderOutput whose `head`/`html`/`body` are NON-ENUMERABLE getters,
# so LiveSvelte 0.15's NodeJS bridge JSON-serialised it to `{}` and no markup
# reached Elixir. assets/js/server.js now wraps LiveSvelte's getRender and
# flattens that output into a plain `{head, html}` object before it crosses the
# bridge. See docs/adr/0008-svelte-ssr.md. The NodeJS supervisor starts
# automatically when SSR is enabled and priv/svelte/server.js exists.
config :live_svelte,
  ssr: true

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

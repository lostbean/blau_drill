import Config

# For development, we disable any cache and enable
# debugging and code reloading.
#
# The watchers configuration can be used to run external
# watchers to your application. For example, we can use it
# to bundle .js and .css sources.
config :blau_drill, BlauDrillWeb.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  # Change to `ip: {0, 0, 0, 0}` to allow access from other machines.
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "AyNxXeWrwH/vSv4iN29OpN/Kv7UtbnbvBbXQgLEAGPEEAUc5I9nvz53Axrz9whUB",
  watchers: [
    # JS (incl. Svelte client + SSR bundles) via the LiveSvelte build.js script.
    node: ["build.js", "--watch", cd: Path.expand("../assets", __DIR__)],
    # CSS via the tailwind binary.
    tailwind: {Tailwind, :install_and_run, [:blau_drill, ~w(--watch)]}
  ]

# Reload browser tabs when matching files change.
config :blau_drill, BlauDrillWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/blau_drill_web/(controllers|live|components)/.*\.(ex|heex)$",
      ~r"lib/blau_drill_web/router\.ex$"
    ]
  ]

# Enable dev routes for debugging-related tooling.
config :blau_drill, dev_routes: true

# Drive the operator UI against a no-hardware **simulator** in dev: the LiveView
# starts a per-session PrinterConnection backed by BlauDrill.PrinterConnection.
# UART.Sim, which tracks a simulated head position so jogs move the live
# crosshair and dry-run/drill streams complete — all with nothing plugged in.
# This never moves anything physical; flip to `backend: :real, port: "..."` to
# drive a real printer. (Energize-before-jog and the M112 abort still apply.)
config :blau_drill, BlauDrill.Printer, backend: :sim, settle_ms: 0

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  # Include debug annotations and locations in rendered markup.
  # Changing this configuration will require mix clean and a full recompile.
  debug_heex_annotations: true,
  debug_attributes: true,
  # Enable helpful, but potentially expensive runtime checks
  enable_expensive_runtime_checks: true

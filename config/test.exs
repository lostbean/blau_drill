import Config

# We run a server during test only if explicitly required (e.g. for
# integration tests). It is disabled by default.
config :blau_drill, BlauDrillWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "QMQOefzFR5s8+jgdAdU95VjxXVExvQuDxJQkTcSUdeuJEeEeD1sWvKyH4eO6FkVs",
  server: false

# Disable LiveSvelte SSR in tests — there is no Node SSR process running, and
# components are not exercised in the unit suite.
config :live_svelte, ssr: false

# No printer backend by default in tests. Gate-behaviour LiveView tests opt into
# a fake wire per-test by passing `connect: {BlauDrill.PrinterConnection.UART.
# Fake, handle}` to the mount (see SessionLive `connect_printer/1` and the
# session_live_test). This keeps the suite hardware-free.
config :blau_drill, BlauDrill.Printer, backend: :none, settle_ms: 0

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

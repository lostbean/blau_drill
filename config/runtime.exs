import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/blau_drill start
#
if System.get_env("PHX_SERVER") do
  config :blau_drill, BlauDrillWeb.Endpoint, server: true
end

config :blau_drill, BlauDrillWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "localhost"

  config :blau_drill, BlauDrillWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # This is a single-bench desktop app — bind to loopback by default.
      # Set BLAU_DRILL_BIND_ALL=1 to bind on all interfaces instead.
      ip:
        if(System.get_env("BLAU_DRILL_BIND_ALL"),
          do: {0, 0, 0, 0, 0, 0, 0, 0},
          else: {127, 0, 0, 1}
        ),
      port: String.to_integer(System.get_env("PORT", "4000"))
    ],
    secret_key_base: secret_key_base
end

defmodule BlauDrill.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        BlauDrillWeb.Telemetry,
        {Phoenix.PubSub, name: BlauDrill.PubSub}
      ] ++
        printer_connection_children() ++
        svelte_ssr_children() ++
        [
          # Start to serve requests, typically the last entry
          BlauDrillWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: BlauDrill.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Supervise `BlauDrill.PrinterConnection` (the serial link to Marlin) only when
  # explicitly enabled in config. It owns the single serial port and enforces the
  # safety-gate model (no motion without an explicit enable gate; M112 abort
  # always wired). Kept OPT-IN so a fresh checkout, `mix test`, and
  # `mix phx.server` all boot with no printer plugged in. Even when enabled, the
  # statem itself starts in a `:faulted` (not-connected) state rather than
  # crashing when the configured port is absent — the operator `reconnect/1`s
  # once the hardware appears. Enable in `config/*.exs` with, e.g.:
  #
  #     config :blau_drill, BlauDrill.PrinterConnection,
  #       enabled: true, port: "ttyUSB0"
  defp printer_connection_children do
    config = Application.get_env(:blau_drill, BlauDrill.PrinterConnection, [])

    if Keyword.get(config, :enabled, false) do
      opts = Keyword.drop(config, [:enabled])
      [{BlauDrill.PrinterConnection, opts}]
    else
      []
    end
  end

  # Starts the NodeJS pool that LiveSvelte uses to server-side render Svelte
  # components, but only when SSR is enabled AND the built SSR bundle exists
  # (priv/svelte/server.js, produced by `mix assets.build`). This keeps fresh
  # checkouts and the test env (ssr: false) booting without a Node build.
  defp svelte_ssr_children do
    ssr_enabled? = Application.get_env(:live_svelte, :ssr, false)
    server_path = Application.app_dir(:blau_drill, "priv/svelte")

    if ssr_enabled? and File.exists?(Path.join(server_path, "server.js")) do
      [{NodeJS.Supervisor, [path: server_path, pool_size: 4]}]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BlauDrillWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

defmodule BlauDrillWeb.Router do
  use BlauDrillWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BlauDrillWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", BlauDrillWeb do
    pipe_through :browser

    # Single entry point. The real five-stage workflow (Load & Connect →
    # Physical Alignment → Dry-run → Active Drilling → Completion) will be
    # driven from this LiveView as the implementation grows.
    live "/", SessionLive, :index

    # The printer configuration / settings screen — a SEPARATE route from the
    # operator flow. It edits a working BlauDrill.Config; "Apply" sets what the
    # NEXT session snapshots at mount (see BlauDrill.Config "resolve once" rule).
    live "/settings", SettingsLive, :index
  end

  # Other scopes may use custom stacks.
  # scope "/api", BlauDrillWeb do
  #   pipe_through :api
  # end
end

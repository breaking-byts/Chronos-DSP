defmodule ChronosWeb.Router do
  use ChronosWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :export do
    plug(:accepts, ["csv", "json"])
  end

  scope "/", ChronosWeb do
    pipe_through(:api)
    get("/healthz", HealthController, :health)
    get("/readyz", HealthController, :ready)
  end

  scope "/api", ChronosWeb do
    pipe_through(:export)
    get("/export/metrics", ExportController, :metrics)
    get("/export/samples", ExportController, :samples)
  end

  scope "/", ChronosWeb do
    pipe_through(:browser)
    live("/", SimLive, :index)
  end
end

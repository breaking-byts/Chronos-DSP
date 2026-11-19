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
    plug(:accepts, ["csv"])
  end

  scope "/", ChronosWeb do
    pipe_through(:api)
    get("/healthz", HealthController, :health)
    get("/readyz", HealthController, :ready)
    post("/api/simulate", SimulationController, :simulate)

    get("/api/scenes", SceneController, :index)
    post("/api/scenes", SceneController, :create)
    get("/api/scenes/:name", SceneController, :show)
    delete("/api/scenes/:name", SceneController, :delete)
  end

  scope "/api", ChronosWeb do
    pipe_through(:export)
    get("/export/metrics", ExportController, :metrics)
    get("/export/history", ExportController, :history)
    get("/export/samples", ExportController, :samples)
  end

  scope "/", ChronosWeb do
    pipe_through(:browser)
    live("/", SimLive, :index)
  end
end

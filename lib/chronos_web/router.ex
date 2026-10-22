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

  scope "/", ChronosWeb do
    pipe_through(:api)
    get("/healthz", HealthController, :health)
    get("/readyz", HealthController, :ready)
  end

  scope "/", ChronosWeb do
    pipe_through(:browser)
    live("/", SimLive, :index)
  end
end

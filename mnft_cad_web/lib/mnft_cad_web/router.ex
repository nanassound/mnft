defmodule MnftCadWeb.Router do
  use MnftCadWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MnftCadWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug MnftCadWeb.OwnerPlug
  end

  scope "/", MnftCadWeb do
    pipe_through :browser

    live_session :app,
      on_mount: {MnftCadWeb.OwnerPlug, :assign_owner} do
      live "/", HomeLive
      live "/app", SessionIndexLive
      live "/app/s/:session_id", CadLive
    end

    get "/m/:model_id/:filename", CadModelController, :download
  end
end

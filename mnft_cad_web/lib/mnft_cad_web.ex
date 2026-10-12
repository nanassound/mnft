defmodule MnftCadWeb do
  @moduledoc """
  The entrypoint for defining the web interface: controllers, components,
  live views. Use as:

      use MnftCadWeb, :controller
      use MnftCadWeb, :live_view
  """

  def static_paths, do: ~w(assets fonts images samples favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: MnftCadWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      use Gettext, backend: MnftCadWeb.Gettext

      import Phoenix.HTML
      import MnftCadWeb.CoreComponents

      alias Phoenix.LiveView.JS
      alias MnftCadWeb.Layouts

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: MnftCadWeb.Endpoint,
        router: MnftCadWeb.Router,
        statics: MnftCadWeb.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end

defmodule MnftCadWeb.SessionIndexLive do
  use MnftCadWeb, :live_view

  alias Mnft.Cad

  @impl true
  def mount(_params, _session, socket) do
    sessions = Cad.list_sessions(socket.assigns.owner_id)

    {:ok,
     socket
     |> assign(:page_title, "Your parts")
     |> assign(:empty?, sessions == [])
     |> stream(:sessions, sessions)}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:ok, session} = Cad.create_session(socket.assigns.owner_id)
    {:noreply, push_navigate(socket, to: ~p"/app/s/#{session.id}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto w-full max-w-3xl px-4 py-10 sm:px-6">
        <div class="flex items-end justify-between gap-4">
          <div>
            <h1 class="font-display text-2xl font-semibold tracking-tight">Your parts</h1>
            <p class="mt-1 text-sm text-zinc-500">Each chat is one part you are iterating on.</p>
          </div>
          <.button id="new-session" variant="primary" phx-click="new">
            <.icon name="hero-plus" class="size-4" /> New part
          </.button>
        </div>

        <div
          id="sessions"
          phx-update="stream"
          class="mt-8 divide-y divide-zinc-200 rounded-xl border border-zinc-200 bg-white"
        >
          <div
            class="hidden only:block px-6 py-12 text-center text-sm text-zinc-500"
            id="sessions-empty"
          >
            Nothing yet. Start a part and describe what you need in plain words.
          </div>
          <.link
            :for={{id, session} <- @streams.sessions}
            id={id}
            navigate={~p"/app/s/#{session.id}"}
            class="flex items-center justify-between px-5 py-4 hover:bg-zinc-50"
          >
            <span class="truncate text-sm font-medium text-zinc-900">
              {if session.title == "", do: "Untitled part", else: session.title}
            </span>
            <span class="ml-4 shrink-0 font-mono text-xs text-zinc-400">
              {Calendar.strftime(session.inserted_at, "%b %d, %H:%M")}
            </span>
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end
end

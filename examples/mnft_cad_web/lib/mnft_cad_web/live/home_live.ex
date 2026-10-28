defmodule MnftCadWeb.HomeLive do
  use MnftCadWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Chat to CAD")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex-1 overflow-y-auto">
        <section class="mx-auto flex min-h-[calc(100dvh-3.5rem)] w-full max-w-3xl flex-col items-start justify-center gap-6 px-4 py-12 sm:px-6">
          <h1 class="font-display text-4xl font-bold leading-[1.05] tracking-tighter text-zinc-900 sm:text-5xl">
            Chat to CAD, open source.
          </h1>
          <p class="max-w-[46ch] text-lg leading-relaxed text-zinc-600">
            Describe a part in plain words. A model writes parametric code, builds the solid, and you inspect and download it — STL, STEP, GLB.
          </p>
          <.link
            id="cta-primary"
            navigate={~p"/app"}
            class="inline-flex items-center gap-2 rounded-lg bg-accent px-5 py-3 text-sm font-medium text-white transition-colors hover:bg-accent-strong active:translate-y-px"
          >
            Start building <.icon name="hero-arrow-right" class="size-4" />
          </.link>
        </section>

        <footer class="border-t border-zinc-200 bg-white px-4 py-6 text-center text-xs text-zinc-500">
          mnft_cad_web — reference app for the mnft_cad core
        </footer>
      </div>
    </Layouts.app>
    """
  end
end

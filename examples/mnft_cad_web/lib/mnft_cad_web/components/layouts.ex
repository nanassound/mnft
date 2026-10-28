defmodule MnftCadWeb.Layouts do
  @moduledoc """
  Layouts. The `app` layout renders the top navigation: brand wordmark on the
  left, a link to the parts list on the right. No accounts — everyone is an
  anonymous owner.
  """
  use MnftCadWeb, :html

  embed_templates("layouts/*")

  attr(:flash, :map, required: true, doc: "the map of flash messages")

  # Controller-rendered pages pass inner_content instead of an inner_block.
  attr(:inner_content, :any, default: nil)

  slot(:inner_block)

  def app(assigns) do
    ~H"""
    <header class="flex h-14 shrink-0 items-center justify-between border-b border-zinc-200 bg-white px-4 sm:px-6">
      <div class="flex items-center gap-3">
        <.link href={~p"/"} class="flex items-center gap-2.5">
          <span class="grid size-7 place-items-center rounded-lg bg-accent">
            <.icon name="hero-cube-transparent" class="size-4.5 text-white" />
          </span>
          <span class="font-display text-[15px] font-semibold tracking-tight text-zinc-900">
            mnft cad
          </span>
        </.link>
      </div>

      <div class="flex items-center gap-2">
        <.link
          href={~p"/app"}
          class="rounded-lg px-3 py-1.5 text-sm font-medium text-accent hover:bg-accent-soft"
        >
          Open app
        </.link>
      </div>
    </header>

    <main class="flex min-h-0 flex-1 flex-col">
      {@inner_content || render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  attr(:flash, :map, required: true, doc: "the map of flash messages")
  attr(:id, :string, default: "flash-group", doc: "the optional id of flash container")

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end

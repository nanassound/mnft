defmodule MnftCadWeb.CadLive do
  use MnftCadWeb, :live_view

  alias Mnft.Cad
  alias Mnft.Cad.{Images, Message, Sessions}
  alias MnftCadWeb.{ModelURL, PubSubBridge}

  @suggestions [
    {"40 mm hex pen holder, 3 mm wall", "a 40 mm hexagonal pen holder with a 3 mm wall"},
    {"30 mm cube, 12 mm hole", "a 30 mm cube with a 12 mm hole through the middle"},
    {"cable clip for 5 mm cable", "a cable clip for a 5 mm cable"}
  ]

  @impl true
  def mount(%{"session_id" => session_id}, _session, socket) do
    session =
      try do
        Cad.get_session!(socket.assigns.owner_id, session_id)
      rescue
        ArgumentError -> nil
      end

    if session do
      do_mount(socket, session)
    else
      {:ok, socket |> put_flash(:error, "Part not found") |> push_navigate(to: ~p"/app")}
    end
  end

  defp do_mount(socket, session) do
    running? = connected?(socket) && agent_running?(session.id)

    if connected?(socket), do: PubSubBridge.subscribe(session.id)

    messages = Cad.list_messages(session.id)

    {:ok,
     socket
     |> assign(:page_title, if(session.title == "", do: "New part", else: session.title))
     |> assign(:session, session)
     |> assign(:suggestions, @suggestions)
     |> assign(:tab, "chat")
     |> assign(:new_model?, false)
     |> assign(:model, model_view(Cad.latest_model(session.id)))
     |> assign(:running?, running?)
     |> assign(:stage, if(running?, do: "working", else: nil))
     |> assign(:elapsed_s, 0)
     |> assign(:last_message, last_user_text(messages))
     |> assign(:error, nil)
     |> assign(:form, to_form(%{"message" => ""}, as: :chat))
     |> stream(:messages, messages)
     |> tick_if(running?)}
  end

  @impl true
  def handle_event("send", %{"message" => message} = params, socket) do
    message = String.trim(message)

    cond do
      message == "" ->
        {:noreply, socket}

      socket.assigns.running? ->
        {:noreply, put_flash(socket, :error, "A build is already running for this part.")}

      true ->
        photos = Map.get(params, "photos", [])
        current = Map.get(params, "current")

        case Sessions.request_turn(socket.assigns.session, message, photos, current) do
          {:ok, :started} ->
            pending = %Message{
              id: "pending-#{System.unique_integer([:positive])}",
              role: :user,
              content: message,
              meta: %{
                "photos" =>
                  Enum.map(photos, fn p ->
                    %{"label" => p["label"], "thumb" => Images.thumbnail(p)}
                  end)
              }
            }

            {:noreply,
             socket
             |> assign(:running?, true)
             |> assign(:stage, "starting")
             |> assign(:elapsed_s, 0)
             |> assign(:error, nil)
             |> assign(:last_message, message)
             |> assign(:form, to_form(%{"message" => ""}, as: :chat))
             |> stream_insert(:messages, pending)
             |> assign(:pending_id, pending.id)
             |> tick_if(true)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, to_string(reason))}
        end
    end
  end

  def handle_event("retry", _params, socket) do
    handle_event("send", %{"message" => socket.assigns.last_message}, socket)
  end

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ["chat", "model"] do
    {:noreply, socket |> assign(:tab, tab) |> assign(:new_model?, false)}
  end

  @impl true
  def handle_info(:tick, %{assigns: %{running?: true}} = socket) do
    Process.send_after(self(), :tick, 1000)
    {:noreply, update(socket, :elapsed_s, &(&1 + 1))}
  end

  def handle_info(:tick, socket), do: {:noreply, socket}

  def handle_info(%{event: "llm_started"}, socket),
    do: {:noreply, assign(socket, :stage, "thinking")}

  def handle_info(%{event: "exec_started"}, socket),
    do: {:noreply, assign(socket, :stage, "building")}

  def handle_info(%{event: "turn_started"}, socket),
    do: {:noreply, assign(socket, :running?, true) |> tick_if(true)}

  def handle_info(%{event: event}, socket) when event in ["llm_done", "exec_done"],
    do: {:noreply, socket}

  def handle_info(%{event: event, payload: payload}, socket)
      when event in ["turn_done", "turn_failed"] do
    session = socket.assigns.session
    messages = Cad.list_messages(session.id) |> Enum.take(-2)

    socket =
      if socket.assigns[:pending_id],
        do: stream_delete_by_dom_id(socket, :messages, "messages-#{socket.assigns.pending_id}"),
        else: socket

    socket =
      Enum.reduce(messages, socket, fn m, acc -> stream_insert(acc, :messages, m) end)

    model =
      if payload[:ok] && payload[:artifacts],
        do: model_view(Cad.latest_model(session.id)),
        else: socket.assigns.model

    {:noreply,
     socket
     |> assign(:running?, false)
     |> assign(:stage, nil)
     |> assign(:pending_id, nil)
     |> assign(:model, model)
     |> assign(:new_model?, model != socket.assigns.model && socket.assigns.tab == "chat")
     |> assign(:error, if(payload[:ok], do: nil, else: payload[:error]))
     |> assign(:session, Cad.get_session!(session.owner_id, session.id))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # --- helpers -----------------------------------------------------------------

  defp tick_if(socket, true) do
    if connected?(socket), do: Process.send_after(self(), :tick, 1000)
    socket
  end

  defp tick_if(socket, _), do: socket

  defp agent_running?(session_id) do
    case Sessions.whereis(session_id) do
      nil ->
        false

      server ->
        case Jido.AgentServer.state(server) do
          {:ok, state} -> state.agent.state.status != :idle
          _ -> false
        end
    end
  end

  defp last_user_text(messages) do
    messages
    |> Enum.filter(&(&1.role == :user))
    |> List.last()
    |> then(&((&1 && &1.content) || ""))
  end

  defp model_view(nil), do: nil

  defp model_view(model) do
    %{
      id: model.id,
      stl: ModelURL.stl(model.id),
      step: ModelURL.step(model.id),
      glb: if(model.has_glb, do: ModelURL.glb(model.id)),
      mesh: model.mesh
    }
  end

  def bbox_line(nil), do: ""

  def bbox_line(%{mesh: %{"bbox_mm" => [x, y, z]} = mesh}) do
    tri = (mesh["triangles"] || 0) |> Integer.to_string() |> add_commas()
    "bbox #{f1(x)} × #{f1(y)} × #{f1(z)} mm · #{tri} triangles"
  end

  def bbox_line(_), do: ""

  defp f1(n), do: :erlang.float_to_binary(n / 1, decimals: 1)

  defp add_commas(s),
    do: s |> String.reverse() |> String.replace(~r/(\d{3})(?=\d)/, "\\1,") |> String.reverse()

  def model_json(nil), do: ""
  def model_json(model), do: Jason.encode!(%{stl: model.stl, mesh: model.mesh, id: model.id})

  # --- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <nav class="flex shrink-0 border-b border-zinc-200 bg-white lg:hidden" aria-label="sections">
        <button
          id="tab-chat"
          phx-click="tab"
          phx-value-tab="chat"
          class={[
            "flex-1 border-b-2 py-3 text-sm font-medium",
            if(@tab == "chat",
              do: "border-accent text-accent",
              else: "border-transparent text-zinc-500"
            )
          ]}
        >
          Chat
        </button>
        <button
          id="tab-model"
          phx-click="tab"
          phx-value-tab="model"
          class={[
            "flex-1 border-b-2 py-3 text-sm font-medium",
            if(@tab == "model",
              do: "border-accent text-accent",
              else: "border-transparent text-zinc-500"
            )
          ]}
        >
          Model
          <span
            :if={@new_model?}
            class="ml-1 rounded-full bg-accent px-1.5 py-0.5 text-[10px] text-white"
          >new</span>
        </button>
      </nav>

      <div class="flex min-h-0 flex-1">
        <section class={[
          "min-h-0 w-full flex-col border-zinc-200 bg-white lg:flex lg:w-[440px] lg:shrink-0 lg:border-r",
          if(@tab == "chat", do: "flex", else: "hidden")
        ]}>
          <div
            id="transcript"
            phx-hook="Transcript"
            class="min-h-0 flex-1 space-y-4 overflow-y-auto px-4 py-5"
          >
            <div id="messages" phx-update="stream" class="space-y-4">
              <div
                id="messages-empty"
                class="hidden only:block py-10 text-center text-sm text-zinc-500"
              >
                Describe a part to begin. Dimensions in millimetres work best.
              </div>
              <.message :for={{id, m} <- @streams.messages} id={id} message={m} />
            </div>

            <div
              :if={@running?}
              id="turn-status"
              class="flex items-center gap-2 text-sm text-zinc-500"
              role="status"
            >
              <span class="flex gap-1" aria-hidden="true">
                <span class="size-1.5 animate-bounce rounded-full bg-accent [animation-delay:-0.3s]"></span>
                <span class="size-1.5 animate-bounce rounded-full bg-accent [animation-delay:-0.15s]"></span>
                <span class="size-1.5 animate-bounce rounded-full bg-accent"></span>
              </span>
              {@stage} · <span class="font-mono">{@elapsed_s}s</span>
            </div>

            <div
              :if={@error && !@running?}
              id="turn-error"
              class="rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-800"
            >
              {@error}
            </div>
          </div>

          <div id="composer" phx-hook="PhotoAttach" class="shrink-0 border-t border-zinc-200 p-3">
            <div
              :if={@last_message == "" and !@running?}
              id="suggestions"
              class="mb-2 flex flex-wrap gap-1.5"
            >
              <button
                :for={{label, prompt} <- @suggestions}
                type="button"
                data-prompt={prompt}
                class="rounded-full border border-zinc-200 bg-white px-3 py-1 text-xs text-zinc-700 hover:border-accent hover:text-accent"
              >
                {label}
              </button>
            </div>
            <div id="attachments" phx-update="ignore" class="mb-2 flex gap-2 empty:hidden"></div>
            <form id="chat-form" class="flex items-end gap-2">
              <button
                type="button"
                data-attach
                aria-label="Attach a photo"
                class="grid size-10 shrink-0 place-items-center rounded-lg border border-zinc-300 text-zinc-600 hover:bg-zinc-50"
              >
                <.icon name="hero-camera" class="size-5" />
              </button>
              <input type="file" accept="image/*" multiple hidden data-file />
              <input
                id="chat-input"
                name="message"
                type="text"
                autocomplete="off"
                enterkeyhint="send"
                placeholder="Describe a part…"
                disabled={@running?}
                class="h-10 min-w-0 flex-1 rounded-lg border border-zinc-300 bg-white px-3 text-sm outline-none focus:border-accent focus:ring-2 focus:ring-accent-ring disabled:bg-zinc-50"
              />
              <button
                id="send"
                type="submit"
                disabled={@running?}
                class="h-10 rounded-lg bg-accent px-4 text-sm font-medium text-white hover:bg-accent-strong active:translate-y-px disabled:opacity-50"
              >
                Send
              </button>
            </form>
          </div>
        </section>

        <section class={[
          "relative min-h-0 flex-1 lg:block",
          if(@tab == "model", do: "block", else: "hidden")
        ]}>
          <div
            id="cad-viewer"
            phx-hook="CadViewer"
            data-model={model_json(@model)}
            class="absolute inset-0 bg-viewer-bg"
          >
            <div id="cad-canvas-wrap" phx-update="ignore" class="absolute inset-0"></div>
          </div>
          <div
            :if={!@model}
            id="model-empty"
            class="pointer-events-none absolute inset-0 grid place-items-center text-sm text-zinc-500"
          >
            No model yet. Describe a part in the chat.
          </div>
          <div class="absolute inset-x-3 top-3 z-10 flex items-center justify-between gap-2">
            <button
              :if={@model}
              id="toggle-edges"
              type="button"
              data-edges
              aria-pressed="true"
              class="rounded-lg border border-zinc-300 bg-white/90 px-3 py-1.5 text-xs font-medium text-zinc-700 hover:bg-white aria-pressed:border-accent aria-pressed:text-accent"
            >
              edges
            </button>
            <div :if={@model} class="flex gap-1.5">
              <a
                href={@model.stl}
                download
                class="rounded-lg border border-zinc-300 bg-white/90 px-3 py-1.5 text-xs font-medium text-zinc-700 hover:bg-white"
              >STL</a>
              <a
                href={@model.step}
                download
                class="rounded-lg border border-zinc-300 bg-white/90 px-3 py-1.5 text-xs font-medium text-zinc-700 hover:bg-white"
              >STEP</a>
              <a
                :if={@model.glb}
                href={@model.glb}
                download
                class="rounded-lg border border-zinc-300 bg-white/90 px-3 py-1.5 text-xs font-medium text-zinc-700 hover:bg-white"
              >GLB</a>
            </div>
          </div>
          <div :if={@model} class="absolute left-3 top-16 z-10 flex flex-col items-start gap-1.5">
            <button
              id="anno-pen"
              type="button"
              data-anno="pen"
              aria-pressed="false"
              class="rounded-lg border border-zinc-300 bg-white/90 px-3 py-1.5 text-xs font-medium text-zinc-700 hover:bg-white aria-pressed:border-accent aria-pressed:text-accent"
            >
              pen
            </button>
            <button
              id="anno-circle"
              type="button"
              data-anno="circle"
              aria-pressed="false"
              class="rounded-lg border border-zinc-300 bg-white/90 px-3 py-1.5 text-xs font-medium text-zinc-700 hover:bg-white aria-pressed:border-accent aria-pressed:text-accent"
            >
              circle
            </button>
            <button
              id="anno-text"
              type="button"
              data-anno="text"
              aria-pressed="false"
              class="rounded-lg border border-zinc-300 bg-white/90 px-3 py-1.5 text-xs font-medium text-zinc-700 hover:bg-white aria-pressed:border-accent aria-pressed:text-accent"
            >
              text
            </button>
            <button
              id="anno-undo"
              type="button"
              data-anno-action="undo"
              class="rounded-lg border border-zinc-300 bg-white/90 px-3 py-1.5 text-xs font-medium text-zinc-700 hover:bg-white"
            >
              undo
            </button>
            <button
              id="anno-clear"
              type="button"
              data-anno-action="clear"
              class="rounded-lg border border-zinc-300 bg-white/90 px-3 py-1.5 text-xs font-medium text-zinc-700 hover:bg-white"
            >
              clear
            </button>
            <button
              id="anno-copy"
              type="button"
              data-anno-action="copy"
              class="rounded-lg border border-accent bg-white/90 px-3 py-1.5 text-xs font-medium text-accent hover:bg-white"
            >
              copy png
            </button>
          </div>
          <div
            :if={@model}
            id="model-info"
            class="absolute inset-x-0 bottom-0 z-10 bg-white/80 px-4 py-2 font-mono text-xs text-zinc-600 backdrop-blur"
          >
            {bbox_line(@model)}
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr(:id, :string, required: true)
  attr(:message, :any, required: true)

  defp message(%{message: %{role: :user}} = assigns) do
    assigns = assign(assigns, :photos, assigns.message.meta["photos"] || [])

    ~H"""
    <div id={@id} class="flex justify-end">
      <div class="max-w-[85%] rounded-xl bg-accent px-3.5 py-2 text-sm text-white">
        {@message.content}
        <div :if={@photos != []} class="mt-1.5 flex flex-wrap gap-1.5">
          <img
            :for={p <- @photos}
            :if={p["thumb"]}
            src={p["thumb"]}
            alt="attached photo"
            class="h-24 w-24 rounded-lg border border-white/40 object-cover"
          />
        </div>
        <div
          :if={@photos != [] and not Enum.any?(@photos, & &1["thumb"])}
          class="mt-1 text-xs text-blue-100"
        >
          {length(@photos)} photo(s) attached
        </div>
      </div>
    </div>
    """
  end

  defp message(assigns) do
    ~H"""
    <div id={@id} class="max-w-[92%] space-y-2">
      <div class="whitespace-pre-wrap rounded-xl border border-zinc-200 bg-zinc-50 px-3.5 py-2 text-sm text-zinc-800">
        {@message.content}
      </div>
      <p :if={@message.meta["repaired"]} class="text-xs text-zinc-500">
        Fixed automatically after a first failed attempt.
      </p>
      <button
        :if={@message.meta["code_missing"]}
        type="button"
        phx-click="retry"
        class="rounded-lg border border-zinc-300 bg-white px-3 py-1 text-xs font-medium text-accent hover:bg-accent-soft"
      >
        try again
      </button>
      <details :if={@message.meta["error_detail"]} class="text-xs text-zinc-600">
        <summary class="cursor-pointer">error detail</summary>
        <pre
          phx-no-curly-interpolation
          class="mt-1 overflow-x-auto rounded-lg bg-zinc-900 p-2 font-mono text-zinc-100"
        ><%= @message.meta["error_detail"] %></pre>
      </details>
      <details :if={@message.code} class="text-xs text-zinc-600">
        <summary class="cursor-pointer">code</summary>
        <pre
          phx-no-curly-interpolation
          class="mt-1 overflow-x-auto rounded-lg bg-zinc-900 p-2 font-mono text-zinc-100"
        ><%= @message.code %></pre>
      </details>
    </div>
    """
  end
end

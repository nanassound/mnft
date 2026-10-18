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
    # Subscribe before reading the agent state: a turn that finishes in
    # between still delivers its turn_done to this view.
    if connected?(socket), do: PubSubBridge.subscribe(session.id)

    info = Sessions.turn_info(session.id)
    running? = info.running

    # Reconnect mid-turn: the in-flight user message lives only in the
    # sending LiveView until the turn persists; rebuild it from turn info.
    {messages, pending_id} = append_pending(Cad.list_messages(session.id), info)

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
     |> assign(:turn_started_ms, if(running?, do: info.started_ms, else: nil))
     |> assign(:elapsed_s, if(running?, do: elapsed_s(info.started_ms), else: 0))
     |> assign(:pending_id, pending_id)
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
        stl = Map.get(params, "stl", %{})
        current = Map.get(params, "current")

        case Sessions.request_turn(socket.assigns.session, message, photos, stl, current) do
          {:ok, :started} ->
            pending = %Message{
              id: "pending-#{System.unique_integer([:positive])}",
              role: :user,
              content: message,
              meta: %{
                "photos" =>
                  Enum.map(photos, fn p ->
                    %{"label" => p["label"], "thumb" => Images.thumbnail(p)}
                  end),
                "stl" =>
                  if stl in [nil, %{}] do
                    nil
                  else
                    %{"name" => stl["name"], "bytes" => stl["size"]}
                  end
              }
            }

            {:noreply,
             socket
             |> assign(:running?, true)
             |> assign(:stage, "starting")
             |> assign(:turn_started_ms, System.system_time(:millisecond))
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
  def handle_info(:tick, %{assigns: %{running?: true, turn_started_ms: started_ms}} = socket)
      when is_integer(started_ms) do
    # Recompute from the real start time so the timer survives tab sleep.
    Process.send_after(self(), :tick, 1000)
    {:noreply, assign(socket, :elapsed_s, elapsed_s(started_ms))}
  end

  def handle_info(:tick, %{assigns: %{running?: true}} = socket) do
    Process.send_after(self(), :tick, 1000)
    {:noreply, update(socket, :elapsed_s, &(&1 + 1))}
  end

  def handle_info(:tick, socket), do: {:noreply, socket}

  def handle_info(%{event: "fetch_started"}, socket),
    do: {:noreply, assign(socket, :stage, "reading reference")}

  def handle_info(%{event: "stl_started"}, socket),
    do: {:noreply, assign(socket, :stage, "analyzing mesh")}

  def handle_info(%{event: "fetch_done"}, socket),
    # the stage chip stays on "reading reference" until llm_started flips it
    do: {:noreply, socket}

  def handle_info(%{event: "llm_started"}, socket),
    do: {:noreply, assign(socket, :stage, "thinking")}

  def handle_info(%{event: "repair_started", payload: p}, socket) do
    {:noreply, assign(socket, :stage, "fixing (round #{p[:round]}/#{p[:rounds]})")}
  end

  # A successful build mid-turn: stream it into the 3D preview immediately.
  def handle_info(%{event: "model_ready", payload: p}, socket) do
    model = model_view(p)

    {:noreply,
     socket
     |> assign(:model, model)
     |> assign(:new_model?, model != socket.assigns.model && socket.assigns.tab == "chat")}
  end

  def handle_info(%{event: "exec_started"}, socket),
    do: {:noreply, assign(socket, :stage, "building")}

  def handle_info(%{event: "turn_started", payload: payload}, socket) do
    started_ms = payload[:started_ms] || System.system_time(:millisecond)

    {:noreply,
     socket
     |> assign(:running?, true)
     |> assign(:turn_started_ms, started_ms)
     |> assign(:elapsed_s, elapsed_s(started_ms))
     |> tick_if(true)}
  end

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
     |> assign(:turn_started_ms, nil)
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

  # Reconnect mid-turn: the in-flight user message lives only in the sending
  # LiveView until the turn persists; rebuild it from the agent's turn info.
  defp append_pending(messages, %{running: true} = info) do
    pending = %Message{
      id: "pending-#{System.unique_integer([:positive])}",
      role: :user,
      content: info.message,
      meta: %{"photos" => info.photos}
    }

    {messages ++ [pending], pending.id}
  end

  defp append_pending(messages, %{running: false}), do: {messages, nil}

  defp elapsed_s(nil), do: 0

  defp elapsed_s(started_ms) when is_integer(started_ms),
    do: max(0, System.system_time(:millisecond) - started_ms) |> div(1000)

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
      gcode: if(Map.get(model, :has_gcode), do: ModelURL.gcode(model.id)),
      script: if(model.script_file, do: ModelURL.file(model.id, model.script_file)),
      script_label: script_label(model.script_file),
      mesh: model.mesh
    }
  end

  defp script_label(nil), do: nil

  defp script_label(name),
    do: name |> Path.extname() |> String.trim_leading(".") |> String.upcase()

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

  @doc """
  Split an assistant reply into renderable segments: `%{kind: :text, text}`
  prose and `%{kind: :code, lang, code}` fenced blocks (`lang` is `nil` for a
  bare fence). A fence is a line starting (after leading whitespace) with
  ```; the fence line's remainder is the language. An unclosed fence runs to
  the end of the reply. Pure: the segments reconstruct the reply exactly, so
  rendering them loses nothing from the raw text.
  """
  @spec md_segments(String.t()) :: [
          %{kind: :text, text: String.t()} | %{kind: :code, lang: String.t() | nil, code: String.t()}
        ]
  def md_segments(content) when is_binary(content) do
    {segs, mode, lang, buf} =
      content
      |> String.split("\n")
      |> Enum.reduce({[], :text, nil, []}, &md_line/2)

    finish_md({segs, mode, lang, buf})
  end

  defp md_line(line, {segs, :text, nil, buf}) do
    if fence?(line),
      do: {flush_text(buf, segs), :code, fence_lang(line), []},
      else: {segs, :text, nil, [line | buf]}
  end

  defp md_line(line, {segs, :code, lang, buf}) do
    if fence?(line),
      do: {flush_code(lang, buf, segs), :text, nil, []},
      else: {segs, :code, lang, [String.replace_suffix(line, "\r", "") | buf]}
  end

  defp finish_md({segs, :text, nil, buf}), do: Enum.reverse(flush_text(buf, segs))
  defp finish_md({segs, :code, lang, buf}), do: Enum.reverse(flush_code(lang, buf, segs))

  defp flush_text([], segs), do: segs

  defp flush_text(buf, segs) do
    case buf |> Enum.reverse() |> Enum.join("\n") do
      "" -> segs
      text -> [%{kind: :text, text: text} | segs]
    end
  end

  defp flush_code(_lang, [], segs), do: segs

  defp flush_code(lang, buf, segs) do
    [%{kind: :code, lang: lang, code: Enum.reverse(buf) |> Enum.join("\n")} | segs]
  end

  defp fence?(line) do
    case String.trim_leading(line) do
      "```" <> _ -> true
      _ -> false
    end
  end

  defp fence_lang(line) do
    case String.trim_leading(line) do
      "```" <> rest ->
        case String.trim(rest) do
          "" -> nil
          lang -> lang
        end

      _ -> nil
    end
  end

  @doc """
  Tokenize prose for inline markdown: `**strong**`, `*em*`, and backtick
  `` `code` `` become `%{kind: :strong | :em | :code, text}`; everything else
  stays `%{kind: :plain, text}`. Emphasis must not open on a space, so
  arithmetic like `2 * 3 * 4` stays plain. Pure and total: a lone unclosed
  marker renders as literal text. Plain tokens concatenate to the input
  exactly; marker tokens carry the inner text without the markers. Callers
  render the tokens with HEEx so the content stays escaped — never build
  HTML strings from LLM text.
  """
  @spec inline_tokens(String.t()) :: [
          %{kind: :plain | :strong | :em | :code, text: String.t()}
        ]
  def inline_tokens(text) when is_binary(text), do: do_inline(text, [])

  # bold first so `**` wins over `*`; em/code must not span a newline.
  @inline_re ~r/\*\*([^*]+)\*\*|\*(\S[^*\n]*?)\*|`([^`\n]+)`/

  defp do_inline(text, acc) do
    case Regex.run(@inline_re, text, return: :index) do
      nil ->
        Enum.reverse(push_plain(text, acc))

      [whole | _] ->
        # Regex indexes are byte offsets; binary-size matching keeps the
        # splits exact even with multibyte characters elsewhere in the text.
        {start, len} = whole
        <<pre::binary-size(^start), match::binary-size(^len), rest::binary>> = text
        acc = [inline_token(match) | push_plain(pre, acc)]
        do_inline(rest, acc)
    end
  end

  defp inline_token("**" <> inner), do: %{kind: :strong, text: String.slice(inner, 0, String.length(inner) - 2)}
  defp inline_token("`" <> inner), do: %{kind: :code, text: String.slice(inner, 0, String.length(inner) - 1)}
  defp inline_token("*" <> inner), do: %{kind: :em, text: String.slice(inner, 0, String.length(inner) - 1)}

  defp push_plain("", acc), do: acc
  defp push_plain(text, acc), do: [%{kind: :plain, text: text} | acc]

  # HEEx escapes interpolated content; safe_to_string keeps the tag-wrapped
  # text escaped too, so LLM text never becomes raw HTML.
  defp render_inline(%{kind: :strong, text: t}), do: {:safe, ["<strong>", safe_to_string(html_escape(t)), "</strong>"]}
  defp render_inline(%{kind: :em, text: t}), do: {:safe, ["<em>", safe_to_string(html_escape(t)), "</em>"]}

  defp render_inline(%{kind: :code, text: t}),
    do:
      {:safe,
       [~s(<code class="rounded bg-zinc-200 px-1 font-mono text-[0.85em]">), safe_to_string(html_escape(t)), "</code>"]}

  defp render_inline(%{kind: :plain, text: t}), do: t

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
                aria-label="Attach a photo or STL"
                title="Attach a photo or STL"
                class="grid size-10 shrink-0 place-items-center rounded-lg border border-zinc-300 text-zinc-600 hover:bg-zinc-50"
              >
                <.icon name="hero-camera" class="size-5" />
              </button>
              <input type="file" accept="image/*,.stl" multiple hidden data-file />
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
          <div
            :if={@running? && @stage}
            id="viewer-progress"
            class="pointer-events-none absolute bottom-3 left-3 z-10 rounded-lg bg-zinc-900/80 px-2.5 py-1.5 font-mono text-xs text-zinc-100"
          >
            {@stage}
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
              <a
                :if={@model.gcode}
                href={@model.gcode}
                download
                class="rounded-lg border border-accent bg-white/90 px-3 py-1.5 text-xs font-medium text-accent hover:bg-white"
              >G-code (GRBL)</a>
              <a
                :if={@model.script}
                href={@model.script}
                download
                class="rounded-lg border border-zinc-300 bg-white/90 px-3 py-1.5 text-xs font-medium text-zinc-700 hover:bg-white"
              >{@model.script_label}</a>
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
    assigns =
      assigns
      |> assign(:photos, assigns.message.meta["photos"] || [])
      |> assign(:stl_chip, stl_chip(assigns.message.meta["stl"]))

    ~H"""
    <div id={@id} class="flex justify-end">
      <div class="max-w-[85%] rounded-xl bg-accent px-3.5 py-2 text-sm text-white [overflow-wrap:anywhere]">
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
        <div :if={@stl_chip} class="mt-1 text-xs text-blue-100">
          {@stl_chip}
        </div>
      </div>
    </div>
    """
  end

  defp message(assigns) do
    ~H"""
    <div id={@id} class="max-w-[92%] space-y-2">
      <%= for {seg, i} <- Enum.with_index(md_segments(@message.content)) do %>
        <%= if seg.kind == :text do %>
          <div class="whitespace-pre-wrap break-words rounded-xl border border-zinc-200 bg-zinc-50 px-3.5 py-2 text-sm text-zinc-800"><%= for tok <- inline_tokens(seg.text) do %>{render_inline(tok)}<% end %></div>
        <% else %>
          <div class="overflow-hidden rounded-xl border border-zinc-700 bg-zinc-900">
            <div class="flex items-center justify-between border-b border-zinc-700 px-3 py-1.5">
              <span class="font-mono text-xs text-zinc-400">{seg.lang || "code"}</span>
              <button
                id={"#{@id}-copy-#{i}"}
                type="button"
                phx-hook="CodeCopy"
                data-target={"#{@id}-code-#{i}"}
                class="text-xs text-zinc-400 transition-colors hover:text-white"
              >copy</button>
            </div>
            <pre
              id={"#{@id}-code-#{i}"}
              phx-no-curly-interpolation
              class="max-h-96 overflow-auto p-3 font-mono text-sm text-zinc-100"
            ><%= seg.code %></pre>
          </div>
        <% end %>
      <% end %>
      <p :if={@message.meta["repaired"]} class="text-xs text-zinc-500">
        Fixed automatically after a first failed attempt.
      </p>
      <div
        :if={not is_nil(@message.meta["cam_note"]) or (@message.meta["cam_warnings"] || []) != []}
        id={"#{@id}-cam"}
        class="rounded-xl border border-amber-300 bg-amber-50 px-3.5 py-2 text-xs text-amber-900"
      >
        <p :if={@message.meta["cam_note"]}>{@message.meta["cam_note"]}</p>
        <ul :if={(@message.meta["cam_warnings"] || []) != []} class="list-inside list-disc">
          <li :for={w <- @message.meta["cam_warnings"]}>{w}</li>
        </ul>
      </div>
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

  # "STL · part.stl · 0.4 MB" — text only, no thumbnail exists for an upload.
  defp stl_chip(nil), do: nil

  defp stl_chip(%{"name" => name} = stl) do
    bytes = stl["bytes"] || 0
    mb = :erlang.float_to_binary(bytes / 1_048_576, decimals: 1)
    "STL · #{name} · #{mb} MB"
  end
end

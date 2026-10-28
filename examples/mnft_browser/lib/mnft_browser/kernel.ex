defmodule MnftBrowser.Kernel do
  @moduledoc """
  The page→BEAM command bridge. JS calls `popcorn.tryCall("mnft_kernel", [cmd | args])`;
  the payload list arrives as the call arguments (binaries as UTF-8 strings).

  Commands:

    * `["turn", session_id, message]` — start a turn; the outcome arrives via
      `cad-event` messages, the reply only says whether the turn started.
    * `["llm_config", provider, base_url, api_key, model]` — swap the core to
      the real `Mnft.Cad.LLM` (BYOK). A blank base URL becomes nil so the
      provider driver's own default endpoint applies (same rule as
      `Mnft.Cad.LLM.model_spec/1`). Keys live only in the browser tab.
  """

  use GenServer

  alias Mnft.Cad.Session

  @owner "browser"

  # The popcorn bridge resolves tryCall targets by REGISTERED NAME: the page
  # calls popcorn.tryCall("mnft_kernel", …), so the registration is the atom,
  # not this module.
  @name :mnft_kernel

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: @name)

  @impl true
  def init(_opts), do: {:ok, %{session: nil}}

  @impl true
  def handle_call(["turn", session_id, message], _from, state) do
    case current_session(session_id, state) do
      {:ok, session} ->
        case Mnft.Cad.Sessions.request_turn(session, message, [], %{}, %{}) do
          {:ok, :started} -> {:reply, %{ok: true}, %{state | session: session}}
          {:error, reason} -> {:reply, %{ok: false, error: reason_to_string(reason)}, state}
        end

      :error ->
        {:reply, %{ok: false, error: "session not found"}, state}
    end
  end

  def handle_call(["llm_config", provider, base_url, api_key, model], _from, state) do
    # The core's LLM path does arithmetic on :timeout_s/:max_tokens and reads
    # :repair_max_elapsed_s (see Mnft.Cad.LLM), so the BYOK switch fills the
    # same defaults the headless embedder config uses.
    # Providers whose module shipped in req_llm register at boot (see
    # register_providers/0); vendors without a module (deepseek, any other
    # OpenAI-compatible endpoint) run through the `openai` provider with
    # their default endpoint unless the user overrides the base URL.
    {provider_atom, base_url} = provider_config(provider, base_url)

    llm =
      Keyword.merge(
        [timeout_s: 600, max_tokens: 32_768, repair_max_elapsed_s: 240],
        provider: provider_atom,
        base_url: base_url,
        api_key: api_key,
        text_model: model,
        vision_model: model
      )

    cfg =
      Mnft.Cad.Config.all()
      |> Keyword.put(:llm_module, Mnft.Cad.LLM)
      |> Keyword.put(:llm, llm)

    Application.put_env(:mnft_cad, :cad, cfg)

    {:reply, %{ok: true, llm: "byok"}, state}
  end

  @impl true
  def handle_call(["debug"], _from, state) do
    {:reply,
     %{
       zai: inspect(ReqLLM.Providers.get(:zai)),
       registry: inspect(ReqLLM.Providers.list()),
       modules_key: inspect(:application.get_key(:req_llm, :modules)),
       zai_loaded: Code.ensure_loaded?(ReqLLM.Providers.Zai),
       zai_behaviour: inspect((ReqLLM.Providers.Zai.__info__(:attributes)[:behaviour] || [])),
       deepseek_module: Code.ensure_loaded?(ReqLLM.Providers.Deepseek)
     }, state}
  end

  @impl true
  def handle_info({:session, %Session{} = session}, state) do
    {:noreply, %{state | session: session}}
  end

  # The store is authoritative (in-memory here); the state copy is only the
  # fallback rebuilt at boot.
  defp current_session(session_id, %{session: %Session{id: session_id} = session}) do
    case Mnft.Cad.store().get_session(@owner, session_id) do
      {:ok, _} -> {:ok, session}
      {:error, :not_found} -> {:ok, session}
    end
  end

  defp current_session(session_id, _state) do
    Mnft.Cad.store().get_session(@owner, session_id)
  end

  defp reason_to_string(reason) when is_binary(reason), do: reason
  defp reason_to_string(reason), do: to_string(reason)

  defp blank_to_nil(url) when is_binary(url) do
    case String.trim(url) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  # Vendors whose OpenAI-compatible endpoint is not a req_llm provider
  # module: route through `openai` with the vendor's default endpoint.
  @openai_compatible %{"deepseek" => "https://api.deepseek.com"}

  defp provider_config(provider, base_url) do
    atom = String.to_atom(provider)

    case ReqLLM.Providers.get(atom) do
      {:ok, _module} ->
        {atom, blank_to_nil(base_url)}

      _ ->
        case Map.fetch(@openai_compatible, provider) do
          {:ok, default_url} -> {:openai, blank_to_nil(base_url) || default_url}
          :error -> {atom, blank_to_nil(base_url)}
        end
    end
  end
end

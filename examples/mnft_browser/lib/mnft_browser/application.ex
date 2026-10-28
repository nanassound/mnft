defmodule MnftBrowser.Application do
  @moduledoc """
  The browser app's tree. `:mnft_cad` starts first (dep app): its own
  supervision tree boots the ETS store (journal off), Jido, the exec
  limiter and the turn supervisor. Then:

    * `Mnft.Cad.LLMFake` — the scripted LLM Agent must be up before any turn
      (boot seeds it; `start_link` tolerating `already_started` matches the
      headless embedder's precedent),
    * `MnftBrowser.Kernel` — the `popcorn.tryCall` command bridge,
    * a boot Task — waits for `Popcorn.JS.await_ready/0`, seeds the script,
      creates the session and announces the boot facts to the page.
  """

  use Application

  @impl true
  def start(_type, _args) do
    register_providers()

    children = [
      Mnft.Cad.LLMFake,
      MnftBrowser.EngineMailbox,
      MnftBrowser.Kernel,
      {Task, &MnftBrowser.Boot.run/0}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MnftBrowser.Supervisor)
  end

  # Under Popcorn, packaged beams carry no `:behaviour` attributes
  # (`__info__(:attributes)[:behaviour]` is [] in the WASM VM), so req_llm's
  # provider discovery AND its register/1 validation both find nothing and
  # every BYOK call falls into the catalog-gateway path, which needs model
  # metadata the gateway check then rejects. Seed the provider registry
  # (req_llm's own persistent_term key) directly, bypassing the
  # attribute-based validation. Vendors without a module (any other
  # OpenAI-compatible endpoint) go through the `openai` provider with a base
  # URL — see Kernel.provider_config/2.
  @provider_registry_key :req_llm_providers

  defp register_providers do
    providers =
      for {id, mod} <- %{
            openai: ReqLLM.Providers.OpenAI,
            anthropic: ReqLLM.Providers.Anthropic,
            zai: ReqLLM.Providers.Zai,
            deepseek: ReqLLM.Providers.Deepseek
          },
          Code.ensure_loaded?(mod),
          into: %{} do
        {id, mod}
      end

    existing = :persistent_term.get(@provider_registry_key, %{})
    :persistent_term.put(@provider_registry_key, Map.merge(existing, providers))

    :ok
  end
end

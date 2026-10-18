defmodule Mnft.Cad.LLM do
  @moduledoc """
  The LLM boundary: req_llm against an OpenAI-compatible chat/completions
  endpoint or a native provider driver (e.g. `:anthropic`); provider/endpoint/
  model are config-only, under `:mnft_cad, :cad, :llm`.

  The adapter is behind the `:llm_module` config seam so the turn pipeline
  can be tested with `Mnft.Cad.LLMFake`.

  `generate/5` never raises and never logs: upstream error text is redacted
  (no image bytes can leak into `error_detail`), image bytes live only inside
  this call.

  `:api_key` resolution: a binary is used as-is; `{:system, "VAR"}` reads the
  environment at call time; `{mod, fun, args}` is applied. A missing/empty
  key yields `{:error, ...}` — never a logged crash.
  """

  import ReqLLM.Context
  alias ReqLLM.Message.ContentPart
  alias Mnft.Cad.{CodeGen, Config, Prompt, PromptOpenscad, PromptSmlibpy}

  @type history :: [%{required(:role) => :user | :assistant, required(:content) => String.t()}]
  @type image :: %{
          required(:data_url) => String.t(),
          required(:media_type) => String.t(),
          optional(atom) => any
        }

  @no_key_error "no LLM API key configured — set llm.api_key (string, {:system, \"VAR\"}, or {mod, fun, args})"

  @spec generate(String.t(), history(), [image()], map() | nil, boolean()) ::
          {:ok, %{reply: String.t(), reasoning: String.t(), finish_reason: term()}}
          | {:error, String.t()}
  def generate(message, history, images, current, vision?) do
    cfg = llm_config()

    case resolve_api_key(cfg[:api_key]) do
      {:ok, key} ->
        do_generate(message, history, images, current, vision?, Keyword.put(cfg, :api_key, key))

      :error ->
        {:error, @no_key_error}
    end
  end

  @doc """
  The model spec for the configured provider. Unverified model ids are
  expected (the glm ids are not in LLMDB). A blank/missing `base_url` is
  omitted so the provider's own driver default applies (e.g. `:anthropic`
  uses its native Messages API endpoint); a configured `base_url` overrides
  it for OpenAI-compatible endpoints.
  """
  def model_spec(vision?) do
    cfg = llm_config()
    id = if vision?, do: cfg[:vision_model], else: cfg[:text_model]

    attrs = %{provider: cfg[:provider] || :openai, id: id}

    case cfg[:base_url] do
      url when is_binary(url) and url != "" -> ReqLLM.model!(Map.put(attrs, :base_url, url))
      _ -> ReqLLM.model!(attrs)
    end
  end

  defp resolve_api_key(key) when is_binary(key) and key != "", do: {:ok, key}

  defp resolve_api_key({:system, var}) when is_binary(var) do
    case System.get_env(var) do
      val when is_binary(val) and val != "" -> {:ok, val}
      _ -> :error
    end
  end

  defp resolve_api_key({m, f, a}) when is_atom(m) and is_atom(f) and is_list(a) do
    case apply(m, f, a) do
      val when is_binary(val) and val != "" -> {:ok, val}
      _ -> :error
    end
  end

  defp resolve_api_key(_), do: :error

  defp do_generate(message, history, images, current, vision?, cfg) do
    model = model_spec(vision?)

    context =
      ReqLLM.Context.new([
        system(system_prompt())
        | Enum.map(history, fn %{role: role, content: content} -> text(role, content) end) ++
            [user_message(message, images, current)]
      ])

    opts = [
      api_key: cfg[:api_key],
      max_tokens: cfg[:max_tokens],
      receive_timeout: cfg[:timeout_s] * 1000,
      total_timeout: cfg[:timeout_s] * 1000
    ]

    case ReqLLM.generate_text(model, context, opts) do
      {:ok, response} ->
        reply = response |> ReqLLM.Response.text() |> String.trim()

        if reply == "" do
          {:error, "model returned empty content (reasoning consumed the token budget)"}
        else
          {:ok,
           %{
             reply: reply,
             reasoning: ReqLLM.Response.thinking(response) || "",
             finish_reason: ReqLLM.Response.finish_reason(response)
           }}
        end

      {:error, error} ->
        {:error, classify_error(error, cfg)}
    end
  end

  defp system_prompt do
    engine = Mnft.Cad.Config.get(:engine)

    dialect =
      if is_atom(engine) and Code.ensure_loaded(engine) == {:module, engine} and
           function_exported?(engine, :dialect, 0) do
        engine.dialect()
      else
        :build123d
      end

    case dialect do
      :smlibpy -> PromptSmlibpy.system() <> PromptSmlibpy.skills_block()
      :openscad -> PromptOpenscad.system() <> PromptOpenscad.skills_block()
      _ -> Prompt.system() <> Prompt.cam_block() <> Prompt.skills_block()
    end
  end

  defp user_message(message, images, current) do
    case CodeGen.build_user_content(message, images, current) do
      text when is_binary(text) ->
        user(text)

      parts when is_list(parts) ->
        user(Enum.map(parts, &to_content_part(&1, images)))
    end
  end

  defp to_content_part(%{type: :text, text: text}, _images), do: ContentPart.text(text)

  defp to_content_part(%{type: :image_url, data_url: data_url}, images) do
    image = Enum.find(images, &(&1.data_url == data_url))
    ContentPart.image(image.bytes, image.media_type)
  end

  defp classify_error(error, cfg) do
    msg = error_message(error)

    if timeout?(error, msg) do
      CodeGen.timeout_message(cfg[:timeout_s])
    else
      CodeGen.redact_data_urls(msg)
    end
  end

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(%{reason: reason}) when is_binary(reason), do: reason
  defp error_message(error) when is_binary(error), do: error
  defp error_message(error), do: inspect(error)

  defp timeout?(%struct{}, _msg) when struct in [ReqLLM.Error.API.Timeout], do: true
  defp timeout?(_error, msg), do: msg =~ "timeout" or msg =~ "timed out"

  defp llm_config, do: Config.llm()
end

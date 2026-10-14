defmodule Mnft.Cad.Turn do
  @moduledoc """
  One chat turn: LLM -> extract -> static-check+execute (inside the engine)
  -> exactly one automatic repair attempt, budget-capped — ported
  branch-for-branch from the PoC's `backend/main.py` `chat()`.

  Runs in a supervised Task (never inside the agent server); reports progress
  via stage events (`Mnft.Cad.Events`), persists the finished turn, and
  always sends `turn.finish` back to the session agent. Never raises.
  """

  require Logger

  alias Mnft.Cad
  alias Mnft.Cad.{CodeGen, Config, Events, Images, Model, PhotoCache, Sessions}

  @truncated_headline "the model's answer was cut off before the code block finished (token limit)"
  @fence_headline "the model's reply contained a code fence but no complete code block"

  def run(session_id, owner_id, message, photos, current) do
    t0 = System.monotonic_time()

    try do
      session = Cad.get_session!(owner_id, session_id)

      result = process(session, message, photos, current || %{}, t0)
      persist(session, message, result)
      emit_telemetry(session, result, t0)

      public(result)
    rescue
      e ->
        detail = Exception.format(:error, e, __STACKTRACE__)

        Logger.error("cad turn crashed: #{Exception.message(e)}")

        result =
          base_result(%{session_id: session_id, owner_id: owner_id})
          |> Map.merge(%{
            error: CodeGen.error_summary(detail),
            error_detail: CodeGen.redact_data_urls(String.slice(detail, 0, 2000))
          })

        Events.emit(session_id, "turn_failed", public(result))
        public(result)
    after
      Sessions.finish_turn(session_id, %{})
    end
  end

  defp process(session, message, photos, current, t0) do
    cfg = Config.llm()

    with {:ok, user_photos} <- Images.validate(photos),
         {llm_message, ref_images, references} <-
           Cad.references_module().enrich(session.id, message) do
      # fetched datasheet pages take precedence over user photos at the cap
      fetched = Enum.take(ref_images ++ user_photos, 5)

      # No photos and no fetched pages this turn: carry the session's most
      # recent image set (one generation deep, prompt-only). Carried images
      # were validated in their origin turn and are never re-validated.
      images =
        if fetched == [] do
          session.id
          |> PhotoCache.take()
          |> Enum.map(&Map.put(&1, :label, "earlier"))
          |> Enum.take(5)
        else
          fetched
        end

      vision? = images != []
      model_used = if vision?, do: cfg[:vision_model], else: cfg[:text_model]
      history = Cad.llm_history(session.id)
      # the PREVIOUS turn's model, fetched before this turn persists
      prev_model = Cad.latest_model(session.id)

      result_1 =
        base_result(%{
          session_id: session.id,
          owner_id: session.owner_id,
          model: model_used,
          vision: vision?,
          references: references,
          photos_meta: Enum.map(fetched, &photo_meta/1)
        })
        |> ask_and_build(llm_message, history, images, current, vision?, t0)

      result_1 =
        maybe_recheck_noop(result_1, prev_model, llm_message, history, images, current, vision?, t0)

      result =
        maybe_repair(result_1, session, llm_message, history, images, current, vision?, model_used, t0)

      if images != [], do: PhotoCache.put(session.id, images)

      result
    else
      {:error, reason} ->
        base_result(%{session_id: session.id, owner_id: session.owner_id})
        |> Map.put(:error, reason)
    end
  end

  # Journal keeps photo METADATA only (never bytes): label, media type, size,
  # and the small client thumbnail when present. Fetched datasheet pages have
  # no thumb — the chat UI falls back to the photo count.
  defp photo_meta(img) do
    meta = %{label: img.label, media_type: img.media_type, bytes: img.size}
    if img[:thumb], do: Map.put(meta, :thumb, img[:thumb]), else: meta
  end

  defp ask_and_build(base, message, history, images, current, vision?, t0) do
    Events.emit(base.session_id, "llm_started", %{})

    case llm_module().generate(message, history, images, current, vision?) do
      {:error, error} ->
        Events.emit(base.session_id, "llm_done", %{})

        base
        |> Map.put(:error, CodeGen.error_summary(error))
        |> Map.put(:error_detail, String.slice(CodeGen.redact_data_urls(error), 0, 2000))
        |> Map.put(:llm_ms, elapsed_ms(t0))

      {:ok, %{reply: reply, reasoning: reasoning, finish_reason: finish_reason}} ->
        Events.emit(base.session_id, "llm_done", %{})
        llm_ms = elapsed_ms(t0)

        base
        |> Map.put(:reply, reply)
        |> Map.put(:reasoning, reasoning)
        |> Map.put(:llm_ms, llm_ms)
        |> first_attempt(finish_reason)
    end
  end

  defp first_attempt(result, finish_reason) do
    reply = result.reply
    code = CodeGen.extract_code(reply)

    cond do
      code != nil ->
        exec_attempt(result, code, final: true)

      true ->
        reason = CodeGen.truncation_reason(reply, finish_reason)

        if reason == nil and not String.contains?(reply, "```") do
          # conversational answer; no model produced. UI offers "try again".
          result |> Map.put(:ok, true) |> Map.put(:code_missing, true)
        else
          result
          |> Map.put(:truncated, true)
          |> Map.put(:first_code, CodeGen.partial_code(reply))
          |> Map.put(:first_err, if(reason, do: @truncated_headline, else: @fence_headline))
          |> repairable()
        end
    end
  end

  defp exec_attempt(result, code, opts) do
    Events.emit(result.session_id, "exec_started", %{})
    run = engine().execute(code, result.owner_id)
    Events.emit(result.session_id, "exec_done", %{})

    result
    |> Map.update(:exec_ms, 0, &(&1 + (run.exec_ms || 0)))

    if run.ok do
      result
      |> Map.put(:ok, true)
      |> Map.put(:code, code)
      |> Map.put(:artifacts, artifact_urls(run.artifacts))
      |> Map.put(:mesh, run.mesh)
      |> Map.put(:model_id, run.artifacts.model_id)
      |> final(Keyword.get(opts, :final, false))
    else
      case run.stage do
        :static_check ->
          result |> Map.put(:first_code, code) |> Map.put(:first_err, run.error) |> repairable()

        _ ->
          result
          |> Map.put(:first_code, code)
          |> Map.put(:first_err, run.error)
          |> Map.put(:code, code)
          |> Map.put(:error, CodeGen.error_summary(run.error))
          |> Map.put(:error_detail, String.slice(run.error || "", 0, 2000))
          |> repairable()
      end
    end
  end

  defp maybe_repair(
         %{repairable: true} = result,
         _session,
         _message,
         history,
         images,
         current,
         vision?,
         _model_used,
         t0
       ) do
    cfg = Config.llm()
    repair_budget_s = cfg[:repair_max_elapsed_s] || 240

    if elapsed_ms(t0) / 1000 >= repair_budget_s do
      result
      |> Map.put(:code_failed, result.first_code)
      |> Map.put(:code, result.first_code)
      |> Map.put(:error, slow_model_error(result.first_err, repair_budget_s))
      |> final(true)
    else
      Events.emit(result.session_id, "llm_started", %{repair: true})

      repair_message =
        if result.truncated do
          CodeGen.build_truncated_repair_message(engine_dialect(), result.first_code)
        else
          CodeGen.build_repair_message(engine_dialect(), result.first_code || "", result.first_err)
        end

      history2 = history ++ [%{role: :assistant, content: result.reply}]

      case llm_module().generate(repair_message, history2, images, current, vision?) do
        {:error, error} ->
          Events.emit(result.session_id, "llm_done", %{})

          result
          |> Map.put(:code_failed, result.first_code)
          |> Map.update(:llm_ms, 0, &(&1 + elapsed_ms(t0)))
          |> Map.put(:error, CodeGen.error_summary(error))
          |> Map.put(:error_detail, String.slice(CodeGen.redact_data_urls(error), 0, 2000))
          |> final(true)

        {:ok, %{reply: reply, reasoning: reasoning}} ->
          Events.emit(result.session_id, "llm_done", %{})

          code2 = CodeGen.extract_code(reply)

          result
          |> Map.put(:reply, reply)
          |> Map.put(:reasoning, reasoning)
          |> Map.update(:llm_ms, 0, &(&1 + elapsed_ms(t0)))
          |> repair_reply(code2, result)
      end
    end
  end

  defp maybe_repair(
         result,
         _session,
         _message,
         _history,
         _images,
         _current,
         _vision?,
         _model,
         _t0
       ),
       do: result

  # One automatic re-ask when the regenerated model is geometrically identical
  # to the previous one: a correction must change the geometry, or the reply
  # must say why the model stays as-is (production evidence: corrections were
  # "acknowledged" while the code — and therefore the model — stayed the same).
  defp maybe_recheck_noop(
         %{ok: true, code: code, mesh: mesh} = result,
         prev_model,
         message,
         history,
         images,
         current,
         vision?,
         t0
       )
       when is_binary(code) and code != "" do
    budget_s = Config.llm()[:repair_max_elapsed_s] || 240
    turn_budget_s = Config.get(:turn_budget_s, 900)
    elapsed_s = elapsed_ms(t0) / 1000

    if match?(%Model{}, prev_model) and mesh_comparable?(prev_model.mesh) and
         mesh_comparable?(mesh) and mesh_same?(prev_model.mesh, mesh) and
         elapsed_s < budget_s and elapsed_s < turn_budget_s do
      recheck_noop(result, message, history, images, current, vision?, t0)
    else
      result
    end
  end

  defp maybe_recheck_noop(
         result,
         _prev_model,
         _message,
         _history,
         _images,
         _current,
         _vision?,
         _t0
       ),
       do: result

  defp recheck_noop(result, message, history, images, current, vision?, t0) do
    Events.emit(result.session_id, "llm_started", %{noop: true})

    noop_message = CodeGen.build_noop_message(engine_dialect(), message, CodeGen.current_model_line(result.mesh))
    history2 = history ++ [%{role: :assistant, content: result.reply}]

    case llm_module().generate(noop_message, history2, images, current, vision?) do
      {:error, _error} ->
        Events.emit(result.session_id, "llm_done", %{noop: true})

        result
        |> Map.put(:noop_retried, true)
        |> Map.update(:llm_ms, 0, &(&1 + elapsed_ms(t0)))

      {:ok, %{reply: reply}} ->
        Events.emit(result.session_id, "llm_done", %{noop: true})

        result
        |> Map.put(:noop_retried, true)
        |> Map.update(:llm_ms, 0, &(&1 + elapsed_ms(t0)))
        |> noop_exec(CodeGen.extract_code(reply), t0)
    end
  end

  # The first attempt was valid geometry; the re-ask may only improve it.
  # A failed re-ask keeps the first result (never regress), but the extra
  # time actually spent still lands in the turn's accounting.
  defp noop_exec(result, code2, _t0) when is_binary(code2) do
    Events.emit(result.session_id, "exec_started", %{noop: true})
    run = engine().execute(code2, result.owner_id)
    Events.emit(result.session_id, "exec_done", %{noop: true})

    result = Map.update(result, :exec_ms, 0, &(&1 + (run.exec_ms || 0)))

    if run.ok do
      result
      |> Map.put(:code, code2)
      |> Map.put(:mesh, run.mesh)
      |> Map.put(:artifacts, artifact_urls(run.artifacts))
      |> Map.put(:model_id, run.artifacts.model_id)
    else
      result
    end
  end

  defp noop_exec(result, nil, _t0), do: result

  defp mesh_comparable?(%{"bbox_mm" => [x, y, z], "volume_mm3" => v})
       when is_number(x) and is_number(y) and is_number(z) and is_number(v),
       do: true

  defp mesh_comparable?(_), do: false

  # Identical geometry: every bbox axis within 0.001 mm and volume within
  # max(0.01 mm3, 0.1%) — catches comment-only re-emissions, tolerates float noise.
  defp mesh_same?(%{"bbox_mm" => b1, "volume_mm3" => v1}, %{"bbox_mm" => b2, "volume_mm3" => v2}) do
    bbox_same? =
      Enum.zip(b1, b2)
      |> Enum.all?(fn {a, b} -> abs(a - b) <= 0.001 end)

    bbox_same? and abs(v1 - v2) <= max(0.01, abs(v1) * 0.001)
  end

  defp repair_reply(result, nil, first) do
    # the automatic repair returned no code block
    result
    |> Map.put(:code, if(first.truncated, do: nil, else: first.first_code))
    |> Map.put(:code_failed, first.first_code)
    |> Map.put(:error, "the automatic repair returned no code block")
    |> Map.put(:error_detail, String.slice(result.reply || "", -1500, 1500))
    |> final(true)
  end

  defp repair_reply(result, code2, first) do
    result
    |> Map.put(:code_failed, first.first_code)
    |> Map.put(:repaired, true)
    |> repair_exec(code2, first)
  end

  defp repair_exec(result, code2, _first) do
    Events.emit(result.session_id, "exec_started", %{repair: true})
    run = engine().execute(code2, result.owner_id)
    Events.emit(result.session_id, "exec_done", %{repair: true})

    result = Map.update(result, :exec_ms, 0, &(&1 + (run.exec_ms || 0)))

    if run.ok do
      result
      |> Map.put(:code, code2)
      |> Map.put(:ok, true)
      |> Map.put(:error, nil)
      |> Map.put(:error_detail, nil)
      |> Map.put(:artifacts, artifact_urls(run.artifacts))
      |> Map.put(:mesh, run.mesh)
      |> Map.put(:model_id, run.artifacts.model_id)
      |> final(true)
    else
      if run.stage == :static_check do
        result
        |> Map.put(:code, code2)
        |> Map.put(:error, run.error)
        |> final(true)
      else
        result
        |> Map.put(:code, code2)
        |> Map.put(:error, CodeGen.error_summary(run.error))
        |> Map.put(:error_detail, String.slice(run.error || "", 0, 2000))
        |> final(true)
      end
    end
  end

  # --- persistence + events ------------------------------------------------------

  defp persist(session, message, result) do
    user_attrs = %{
      content: message,
      # string keys: the persisted photo metadata is JSON-shaped (hosts may
      # serialize it), so normalize the in-memory atom-keyed map here.
      meta: %{
        "photos" =>
          Enum.map(result[:photos_meta] || [], fn m ->
            Map.new(m, fn {k, v} -> {to_string(k), v} end)
          end),
        # fetched reference datasheets: url + page count + extracted text
        # (already capped at fetch time). Lets later turns — and post-restart
        # turns — see the extracted dimensions instead of a bare URL.
        "references" => result.references || []
      }
    }

    assistant_content =
      if result.reply != "", do: result.reply, else: result.error || "(no reply)"

    assistant_attrs = %{
      content: assistant_content,
      code: result.code,
      meta: %{
        "llm_ms" => result.llm_ms,
        "exec_ms" => result.exec_ms,
        "model" => result.model,
        "vision" => result.vision,
        "repaired" => result.repaired,
        "noop_retried" => result[:noop_retried] || false,
        "code_missing" => result.code_missing,
        "error" => result.error,
        "error_detail" => result.error_detail,
        "code_failed" => result.code_failed
      }
    }

    model_attrs =
      if result.ok and result.model_id do
        %{
          id: result.model_id,
          mesh: normalize_mesh(result.mesh),
          has_glb: !is_nil(result.artifacts[:glb])
        }
      else
        nil
      end

    case Cad.record_turn(session, user_attrs, assistant_attrs, model_attrs) do
      {:ok, _} ->
        Cad.set_title_if_blank(session, message)
        :ok

      {:error, reason} ->
        Logger.error("cad turn persistence failed: #{inspect(reason)}")
        :error
    end
  end

  defp emit_telemetry(_session, result, t0) do
    :telemetry.execute(
      [:mnft_cad, :cad, :turn],
      %{total_ms: elapsed_ms(t0), llm_ms: result.llm_ms, exec_ms: result.exec_ms},
      %{
        ok: result.ok,
        vision: result.vision,
        repaired: result.repaired,
        code_missing: result.code_missing
      }
    )

    Events.emit(result.session_id, "turn_done", public(result))
  end

  # The payload hosts receive.
  defp public(result) do
    %{
      reply: result.reply,
      reasoning: result.reasoning,
      code: result.code,
      ok: result.ok,
      error: result.error,
      error_detail: result.error_detail,
      repaired: result.repaired,
      code_failed: result.code_failed,
      code_missing: result.code_missing,
      artifacts: result.artifacts,
      mesh: result.mesh,
      meta: %{
        llm_ms: result.llm_ms,
        exec_ms: result.exec_ms,
        model: result.model,
        vision: result.vision
      }
    }
  end

  defp base_result(over) do
    %{
      session_id: "",
      owner_id: "",
      reply: "",
      reasoning: "",
      code: nil,
      ok: false,
      error: nil,
      error_detail: nil,
      repaired: false,
      noop_retried: false,
      code_failed: nil,
      code_missing: false,
      artifacts: nil,
      mesh: nil,
      model_id: nil,
      llm_ms: 0,
      exec_ms: 0,
      model: Config.llm()[:text_model],
      vision: false,
      truncated: false,
      first_code: nil,
      first_err: nil,
      repairable: false,
      photos_meta: [],
      references: []
    }
    |> Map.merge(Map.new(over))
  end

  defp repairable(result), do: Map.put(result, :repairable, true)
  defp final(result, _), do: Map.put(result, :repairable, false)

  defp slow_model_error(first_err, budget_s) do
    "#{CodeGen.error_summary(first_err)} — the model was too slow on this attempt, " <>
      "so the automatic repair was skipped (turn budget #{trunc(budget_s)} s); " <>
      "try again or ask for a simpler part"
  end

  # Artifact paths on disk (host maps them to URLs however it serves files).
  defp artifact_urls(nil), do: nil

  defp artifact_urls(art) do
    %{model_id: art.model_id, stl: art.stl, step: art.step, glb: art.glb}
  end

  defp normalize_mesh(nil), do: %{}

  defp normalize_mesh(mesh) when is_map(mesh) do
    %{
      "triangles" => mesh["triangles"],
      "bbox_mm" => mesh["bbox_mm"],
      "volume_mm3" => mesh["volume_mm3"]
    }
  end

  defp normalize_mesh(mesh) when is_list(mesh), do: Map.new(mesh)

  defp elapsed_ms(t0),
    do: System.convert_time_unit(System.monotonic_time() - t0, :native, :millisecond)

  defp llm_module, do: Cad.llm_module()

  defp engine, do: Cad.engine()

  defp engine_dialect do
    engine = Config.get(:engine)

    if is_atom(engine) and Code.ensure_loaded(engine) == {:module, engine} and
         function_exported?(engine, :dialect, 0) do
      engine.dialect()
    else
      :build123d
    end
  end
end

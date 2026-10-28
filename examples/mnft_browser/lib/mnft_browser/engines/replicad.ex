defmodule MnftBrowser.Engines.Replicad do
  @moduledoc """
  The browser engine behind `:engine`: hands generated JS to the page-side
  replicad/OCCT worker (`window.__mnftEngine`) via `Popcorn.JS.run!/2` and
  waits for the worker's `engine_result` message. Executions are serialized
  through `Mnft.Cad.ExecLimiter` (parity with `Engines.PythonWorker`).

  Mesh/STL/STEP BYTES never enter the BEAM: the page stores them under
  `window.__mnftArtifacts[model_id]` before casting the result, and the
  artifacts here are `mem://` handles the page resolves for downloads.
  """

  @behaviour Mnft.Cad.Engine

  alias Mnft.Cad.{Config, ExecLimiter}
  alias MnftBrowser.EngineMailbox
  alias Popcorn.JS

  @impl true
  def dialect, do: :replicad

  @doc "Readiness is gated page-side (OCCT wasm load); the engine is always willing."
  @impl true
  def healthy?, do: true

  @impl true
  def execute(code, _owner_id) do
    model_id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    t0 = now_ms()

    # The page reports back to the mailbox by NAME (string routing is
    # guaranteed); registration precedes the dispatch so a result can never
    # arrive unclaimed.
    EngineMailbox.expect(model_id)

    # `{send}` is the raw-delivery action (a proxy cast would arrive
    # GenServer-wrapped); the payload goes to the mailbox's registered name.
    JS.run!(
      "({code, id}, {send}) => { window.__mnftEngine.run(code, id, send); return true; }",
      %{code: code, id: model_id}
    )

    timeout_s = Config.get(:exec_timeout_s, 60)

    ExecLimiter.run(fn ->
      case EngineMailbox.await(model_id, (timeout_s + 5) * 1000) do
        {:ok, res} ->
          map_result(res, model_id, t0)

        :timeout ->
          %{
            ok: false,
            stage: :exec,
            error: "replicad engine timeout after #{timeout_s}s",
            artifacts: nil,
            mesh: nil,
            exec_ms: now_ms() - t0
          }
      end
    end)
  end

  # JS object keys arrive as binaries.
  defp map_result(%{"ok" => true} = res, model_id, t0) do
    stats = res["stats"] || %{}

    %{
      ok: true,
      stage: :exec,
      error: nil,
      artifacts: %{
        model_id: model_id,
        stl: "mem://" <> model_id <> "/model.stl",
        step: "mem://" <> model_id <> "/model.step",
        glb: nil
      },
      mesh: %{
        "triangles" => trunc(num(stats["triangles"])),
        "bbox_mm" => dims(stats["bboxMM"]),
        "volume_mm3" => num(stats["volumeMM3"])
      },
      exec_ms: trunc(num(res["elapsedMs"]) |> fallback(now_ms() - t0))
    }
  end

  defp map_result(%{"ok" => _} = res, _model_id, _t0) do
    stage = if res["stage"] == "static_check", do: :static_check, else: :exec

    %{
      ok: false,
      stage: stage,
      error: res["error"],
      artifacts: nil,
      mesh: nil,
      exec_ms: trunc(num(res["elapsedMs"]))
    }
  end

  defp dims(%{"min" => [x0, y0, z0], "max" => [x1, y1, z1]}) do
    [x1 - x0, y1 - y0, z1 - z0]
  end

  defp dims(_), do: [0.0, 0.0, 0.0]

  defp num(v) when is_number(v), do: v
  defp num(_), do: 0

  defp fallback(0, alt), do: alt
  defp fallback(v, _alt), do: v

  defp now_ms, do: :erlang.system_time(:millisecond)
end

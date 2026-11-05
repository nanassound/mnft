defmodule MnftOcex.Engine do
  @moduledoc """
  The native OCEx engine: executes the `ocex` JSON construction dialect
  in-process on the BEAM via OCEx NIFs (Open CASCADE Technology 7.9.3).

  Implements the `Mnft.Cad.Engine` behaviour; never raises. Static validation
  (`MnftOcex.Dialect`) rejects malformed programs before any native call;
  execution (`MnftOcex.Interpreter`) runs a shape stack over OCEx. Mesh
  measurement and GLB preview reuse the core's pure-Elixir helpers
  (`Mnft.Cad.Engines.OpenScad.Stl` / `.Glb`) so the run contract matches the
  other engines exactly.

  Caveats inherited from OCEx:

  - kernel calls are serialised per BEAM node and cannot be cancelled;
  - a native fault in OCCT kills the whole VM — in production, run this
    engine in its own BEAM node/container so a geometry crash cannot take
    the web application down;
  - STEP export prints OCCT transfer chatter to stdout.
  """

  @behaviour Mnft.Cad.Engine

  alias Mnft.Cad.Engines.OpenScad.{Glb, Stl}
  alias MnftOcex.{Dialect, Interpreter}

  @impl Mnft.Cad.Engine
  @doc "Dialect tag; routes the LLM system prompt and repair messages."
  def dialect, do: :ocex

  @impl Mnft.Cad.Engine
  @doc """
  True when the OCEx NIF and its OCCT toolkit load. No Python, no external
  binary — the compiled NIF is the runtime.
  """
  def healthy? do
    with {:module, _} <- Code.ensure_loaded(OCEx),
         {:ok, _version} <- OCEx.version() do
      true
    else
      _missing_or_failed -> false
    end
  rescue
    _ -> false
  catch
    _kind, _value -> false
  end

  @impl Mnft.Cad.Engine
  def execute(code, owner_id) do
    with {:ok, ops} <- Dialect.validate(code) do
      run(ops, code, owner_id)
    else
      {:error, msg} -> fail(:static_check, msg)
    end
  rescue
    e -> fail(:exec, "ocex runner failure: #{Exception.format(:error, e)}")
  catch
    kind, value -> fail(:exec, "ocex runner failure: #{kind} #{inspect(value)}")
  end

  # --- execution ---------------------------------------------------------------

  defp run(ops, code, owner_id) do
    cfg = Mnft.Cad.Config.all()
    model_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    model_dir = [cfg[:models_dir], owner_id, model_id] |> Path.join() |> Path.absname()

    case File.mkdir_p(model_dir) do
      :ok ->
        script = Path.join(model_dir, "model.ocex.json")
        File.write!(script, code)
        started = System.monotonic_time(:millisecond)

        result = Mnft.Cad.ExecLimiter.run(fn -> Interpreter.run(ops) end)
        exec_ms = System.monotonic_time(:millisecond) - started

        finish(result, model_dir, model_id, script, exec_ms)

      {:error, reason} ->
        fail(:exec, "ocex: cannot create model dir: #{inspect(reason)}")
    end
  end

  defp finish({:ok, shape}, model_dir, model_id, script, exec_ms) do
    stl = Path.join(model_dir, "model.stl")
    step = Path.join(model_dir, "model.step")

    with {:ok, :ok} <- OCEx.write_stl(shape, stl, 0.05, 0.2),
         {:ok, :ok} <- OCEx.write_step(shape, step),
         {:ok, mesh} <- Stl.parse(stl) do
      glb_path = Path.join(model_dir, "model.glb")

      # GLB is a coarse preview only: best-effort, nil on failure.
      glb =
        case Glb.write(stl, glb_path) do
          :ok -> glb_path
          _other -> nil
        end

      %{
        ok: true,
        stage: :exec,
        error: nil,
        artifacts: %{model_id: model_id, stl: stl, step: step, glb: glb, script: script},
        mesh: mesh,
        exec_ms: exec_ms
      }
    else
      {:error, reason} -> fail(:exec, "ocex: export failed (#{inspect(reason)})")
      {:ok, unexpected} -> fail(:exec, "ocex: export returned #{inspect(unexpected)}")
    end
  end

  defp finish({:error, reason}, _model_dir, _model_id, _script, _exec_ms) do
    fail(:exec, reason)
  end

  defp fail(stage, error) do
    %{ok: false, stage: stage, error: error, artifacts: nil, mesh: nil, exec_ms: 0}
  end
end

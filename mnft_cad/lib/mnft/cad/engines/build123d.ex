defmodule Mnft.Cad.Engines.Build123d do
  @moduledoc """
  The Elixir side of the cad_worker boundary: one Python CLI process per
  execution, spoken to over a Port (stdin: one JSON request line, stdout: one
  JSON reply line). The worker owns rlimits, the guarded harness subprocess,
  and its own hard deadline; this module owns the wall clock.

  Implements the `Mnft.Cad.Engine` behaviour; selected via the `:engine`
  config key (tests use `Mnft.Cad.EngineFake`).
  """

  @behaviour Mnft.Cad.Engine

  @impl Mnft.Cad.Engine
  def dialect, do: :build123d

  @impl Mnft.Cad.Engine
  @doc """
  Run `code` inside the owner's directory. Returns the CLI's result map with
  atom keys:

      %{ok: boolean, stage: "static_check" | "exec", error: term,
        artifacts: %{model_id: String.t(), stl: path, step: path, glb: path, script: path | nil} | nil,
        mesh: %{triangles: term, bbox_mm: term, volume_mm3: term} | nil,
        exec_ms: integer}

  Artifacts are absolute file paths (or nil), scoped
  `<models_dir>/<owner_id>/<model_id>`. Never raises.
  """
  def execute(code, owner_id, opts \\ []),
    do: Mnft.Cad.Engines.PythonWorker.execute("build123d", code, owner_id, opts)

  @impl Mnft.Cad.Engine
  @doc "`true` when the worker answers --health (used by the smoke suite)."
  def healthy?, do: Mnft.Cad.Engines.PythonWorker.healthy?("build123d")
end

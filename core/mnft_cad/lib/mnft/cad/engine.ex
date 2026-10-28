defmodule Mnft.Cad.Engine do
  @moduledoc """
  The execution boundary between generated code and geometry.

  Implementations: `Mnft.Cad.Engines.Build123d` (Python worker over a Port;
  STEP/STL/GLB, full fidelity) and `Mnft.Cad.Engines.OpenScad` (the openscad
  binary over a Port; mesh-only — no STEP). Selection is `:engine` under
  `:mnft_cad, :cad` config; tests use `Mnft.Cad.EngineFake`.

  The returned map is the engine contract; the turn pipeline only knows this
  shape:

      %{ok: boolean,
        stage: :static_check | :exec,
        error: String.t() | nil,
        artifacts: %{model_id: String.t(), stl: path, step: path, glb: path | nil, script: path | nil} | nil,
        mesh: %{triangles: term, bbox_mm: [x, y, z], volume_mm3: float} | nil,
        exec_ms: integer}

  `artifacts` carry absolute file paths. `execute/2` never raises; every
  failure mode lands in `ok: false`.
  """

  @type run :: %{
          required(:ok) => boolean(),
          required(:stage) => :static_check | :exec,
          required(:error) => String.t() | nil,
          required(:artifacts) => map() | nil,
          required(:mesh) => map() | nil,
          required(:exec_ms) => non_neg_integer()
        }

  @callback execute(code :: String.t(), owner_id :: String.t()) :: run()

  @doc "Health probe for the engine's runtime (worker --health, binary presence)."
  @callback healthy?() :: boolean()

  @callback dialect() :: atom()

  @optional_callbacks [healthy?: 0, dialect: 0]
end

defmodule Mnft.Cad.Model do
  @moduledoc """
  A successfully built part. Artifacts live at
  `<models_dir>/<owner_id>/<id>/model.{stl,step,glb}` on disk (or wherever
  the host mirrors them), next to the engine script that produced them
  (`model.py` for the Python engines, `model.scad` for OpenSCAD) —
  `script_file` holds the script's filename. `id` is the hex model id
  shared with the engine's output directory name.

  `mesh`: `{"triangles" => n, "bbox_mm" => [x, y, z], "volume_mm3" => v}`.
  """

  defstruct [:id, :session_id, :owner_id, :message_id, :mesh, :has_glb, :script_file, :inserted_at, :updated_at]

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          owner_id: String.t(),
          message_id: String.t() | nil,
          mesh: map(),
          has_glb: boolean(),
          script_file: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }
end

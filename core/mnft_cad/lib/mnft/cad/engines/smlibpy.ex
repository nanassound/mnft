defmodule Mnft.Cad.Engines.Smlibpy do
  @moduledoc "smlibpy (SMLib NURBS kernel) CAD engine via the Python worker."
  @behaviour Mnft.Cad.Engine

  @impl Mnft.Cad.Engine
  def dialect, do: :smlibpy

  @impl Mnft.Cad.Engine
  def execute(code, owner_id), do: Mnft.Cad.Engines.PythonWorker.execute("smlibpy", code, owner_id)

  @impl Mnft.Cad.Engine
  def healthy?, do: Mnft.Cad.Engines.PythonWorker.healthy?("smlibpy")
end

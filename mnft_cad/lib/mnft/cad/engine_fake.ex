defmodule Mnft.Cad.EngineFake do
  @moduledoc """
  Scripted engine for tests and embedders, behind the `:engine` seam.
  `set_script/1` queues results popped per `execute/2` call; every call is
  recorded (`calls/0`). Results mirror the `Mnft.Cad.Engine` contract.
  """
  use Agent

  def start_link(_opts),
    do: Agent.start_link(fn -> %{script: [], calls: []} end, name: __MODULE__)

  def set_script(results), do: Agent.update(__MODULE__, &%{&1 | script: Enum.reverse(results)})

  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

  def execute(code, owner_id, opts \\ []) do
    Agent.get_and_update(__MODULE__, fn state ->
      {result, script} =
        List.pop_at(state.script, -1, %{
          ok: false,
          stage: :exec,
          error: "EngineFake: script exhausted",
          artifacts: nil,
          mesh: nil,
          exec_ms: 0
        })

      {result,
       %{
         state
         | script: script,
           calls: [%{code: code, owner_id: owner_id, cam: opts[:cam]} | state.calls]
       }}
    end)
  end
end

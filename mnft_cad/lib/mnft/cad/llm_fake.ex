defmodule Mnft.Cad.LLMFake do
  @moduledoc """
  Scripted LLM for tests and embedders, behind the `:llm_module` seam.
  `set_script/1` queues replies (an Agent), each popped per call:

    * `{:ok, %{reply: ..., reasoning: ..., finish_reason: ...}}`
    * `{:error, "..."}`

  Records every call for assertions (`calls/0`).
  """
  use Agent

  def start_link(_opts),
    do: Agent.start_link(fn -> %{script: [], calls: []} end, name: __MODULE__)

  def set_script(replies), do: Agent.update(__MODULE__, &%{&1 | script: Enum.reverse(replies)})

  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

  def generate(message, history, images, current, vision?) do
    Agent.get_and_update(__MODULE__, fn state ->
      {reply, script} = List.pop_at(state.script, -1, {:error, "LLMFake: script exhausted"})

      call = %{
        message: message,
        history: history,
        images: images,
        current: current,
        vision?: vision?
      }

      {reply, %{state | script: script, calls: [call | state.calls]}}
    end)
  end
end

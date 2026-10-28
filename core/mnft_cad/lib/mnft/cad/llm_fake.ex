defmodule Mnft.Cad.LLMFake do
  @moduledoc """
  Scripted LLM for tests and embedders, behind the `:llm_module` seam.
  `set_script/1` queues replies (an Agent), each popped per call:

    * `{:ok, %{reply: ..., reasoning: ..., finish_reason: ...}}`
    * `{:error, "..."}`
    * `{:hold, reply}` — block the caller until `release/1`, then answer
      with `reply`; lets tests pin a turn mid-flight (`held/0` lists the
      pending holders)

  Records every call for assertions (`calls/0`).
  """
  use Agent

  def start_link(_opts),
    do: Agent.start_link(fn -> %{script: [], calls: [], holders: []} end, name: __MODULE__)

  def set_script(replies), do: Agent.update(__MODULE__, &%{&1 | script: Enum.reverse(replies)})

  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

  def held, do: Agent.get(__MODULE__, & &1.holders)

  def release(%{pid: pid, ref: ref}), do: send(pid, {:llm_release, ref})

  def generate(message, history, images, current, vision?) do
    reply =
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

    case reply do
      {:hold, reply} ->
        ref = make_ref()
        me = self()

        # runs in the LLMFake server, so capture the caller pid outside
        Agent.update(__MODULE__, &%{&1 | holders: [%{pid: me, ref: ref} | &1.holders]})

        receive do
          {:llm_release, ^ref} -> reply
        after
          30_000 -> {:error, "LLMFake: hold timed out"}
        end

      reply ->
        reply
    end
  end
end

defmodule MnftBrowser.Boot do
  @moduledoc """
  One-time boot inside the browser BEAM: wait for the JS bridge, seed the
  scripted LLM with N turn replies (heights strictly increasing, so the
  core's noop re-check never fires in fake mode), create the single
  session, hand it to the kernel, and tell the page the VM is up.
  """

  alias Popcorn.JS

  @scripted_turns 12

  def run do
    :ok = JS.await_ready()

    Mnft.Cad.LLMFake.set_script(Enum.map(1..@scripted_turns, &scripted_reply/1))

    {:ok, session} = Mnft.Cad.create_session("browser")
    GenServer.cast(MnftBrowser.Kernel, {:session, session})

    JS.send(%{
      type: "boot",
      session_id: session.id,
      otp_release: to_string(:erlang.system_info(:otp_release)),
      engine: "replicad",
      journal: "in-memory",
      llm: "fake"
    })

    :ok
  end

  # Heights 80.0..91.0 strictly increasing: every scripted turn changes the
  # bbox, so the geometric-identity (noop) recheck cannot trigger.
  defp scripted_reply(i) do
    {:ok,
     %{
       reply: "Part (scripted).\n```js\n" <> MnftBrowser.Sample.script(80.0 + (i - 1)) <> "\n```",
       reasoning: "scripted",
       finish_reason: :stop
     }}
  end
end

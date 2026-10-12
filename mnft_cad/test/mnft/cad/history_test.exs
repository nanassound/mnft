defmodule Mnft.Cad.HistoryTest do
  use ExUnit.Case, async: false

  alias Mnft.Cad
  alias Mnft.Cad.{EngineFake, LLMFake, Turn}

  setup do
    owner = "owner-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, session} = Cad.create_session(owner)
    start_supervised!(LLMFake)
    start_supervised!(EngineFake)

    %{owner: owner, session: session}
  end

  defp ok_worker do
    %{
      ok: true,
      stage: :exec,
      error: nil,
      artifacts: %{model_id: "abcdef0123456789", stl: "/x", step: "/x", glb: nil},
      mesh: %{"triangles" => 12, "bbox_mm" => [427.0, 30.0, 30.0], "volume_mm3" => 384_300.0},
      exec_ms: 1
    }
  end

  defp llm_ok(reply), do: {:ok, %{reply: reply, reasoning: "", finish_reason: :stop}}

  test "persisted reference text re-enters later turns' history", %{owner: owner, session: session} do
    LLMFake.set_script([
      llm_ok("Built.\n```python\npart = Box(427, 30, 30)\n```"),
      llm_ok("```python\npart = Box(640, 30, 30)\n```")
    ])

    EngineFake.set_script([ok_worker(), ok_worker()])

    Turn.run(session.id, owner, "rails https://example.com/z-rails.pdf, length 84HP", [], %{})
    Turn.run(session.id, owner, "Make it 126HP", [], %{})

    # the second turn's prompt history carries the extracted datasheet text
    second = Enum.at(LLMFake.calls(), 1)
    user_entry = Enum.find(second.history, &(&1.role == :user))

    assert user_entry.content =~
             "[Reference datasheet text extracted from https://example.com/z-rails.pdf]"

    assert user_entry.content =~ "84 HP = 427 mm length, 23.8 mm deep"
  end

  test "llm_history appends reference text after the slice; clean sessions unaffected", %{
    session: session
  } do
    {:ok, _} =
      Cad.record_turn(
        session,
        %{
          content: "a rails",
          meta: %{
            "references" => [%{"url" => "https://e.com/x.pdf", "pages" => 2, "text" => "L = 427 mm"}]
          }
        },
        %{content: "done", code: nil, meta: %{}},
        nil
      )

    [user, assistant] = Cad.llm_history(session.id)

    assert user.content ==
             "a rails" <>
               "\n\n[Reference datasheet text extracted from https://e.com/x.pdf]\nL = 427 mm"

    assert assistant.content == "done"

    # malformed/absent references never break history
    {:ok, _} =
      Cad.record_turn(
        session,
        %{content: "second", meta: %{"references" => "garbage"}},
        %{content: "ok2", code: nil, meta: %{}},
        nil
      )

    history = Cad.llm_history(session.id)
    assert List.last(history).content == "ok2"
    assert length(history) == 4
  end
end

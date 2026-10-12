defmodule Mnft.Cad.TurnTest do
  @moduledoc """
  The turn pipeline against scripted LLM + engine fakes: every branch the
  PoC's `chat()` had. Runs the real Jido instance + TurnSupervisor +
  ExecLimiter so the whole supervision path is exercised.
  """
  use ExUnit.Case, async: false

  alias Mnft.Cad
  alias Mnft.Cad.{EngineFake, LLMFake, Sessions, TestEvents, Turn}

  setup do
    owner = "owner-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, session} = Cad.create_session(owner)

    TestEvents.set(self())

    on_exit(fn -> TestEvents.unset() end)

    start_supervised!(LLMFake)
    start_supervised!(EngineFake)

    %{owner: owner, session: session}
  end

  defp ok_worker(model_id \\ "abcdef0123456789") do
    %{
      ok: true,
      stage: :exec,
      error: nil,
      artifacts: %{
        model_id: model_id,
        stl: "/tmp/x/model.stl",
        step: "/tmp/x/model.step",
        glb: "/tmp/x/model.glb"
      },
      mesh: %{"triangles" => 12, "bbox_mm" => [30.0, 30.0, 30.0], "volume_mm3" => 27_000.0},
      exec_ms: 250
    }
  end

  defp run_turn(session), do: Turn.run(session.id, session.owner_id, "a 30 mm cube", [], %{})

  defp llm_ok(reply),
    do: {:ok, %{reply: reply, reasoning: "thinking...", finish_reason: :stop}}

  test "happy path: LLM -> exec -> model + persistence + turn_done", %{
    session: session,
    owner: owner
  } do
    LLMFake.set_script([
      llm_ok("Here is the cube.\n```python\npart = Box(30, 30, 30)\n```")
    ])

    EngineFake.set_script([ok_worker()])

    result = run_turn(session)

    assert result.ok
    assert result.artifacts.stl == "/tmp/x/model.stl"
    assert result.artifacts.model_id == "abcdef0123456789"
    assert result.mesh["bbox_mm"] == [30.0, 30.0, 30.0]
    assert result.meta.model == "test-text"
    refute result.meta.vision

    # messages + model persisted
    messages = Cad.list_messages(session.id)
    assert Enum.map(messages, & &1.role) == [:user, :assistant]
    assert hd(messages).meta["photos"] == []
    model = Cad.latest_model(session.id)
    assert model.id == "abcdef0123456789"
    assert model.owner_id == owner

    # session titled from first message
    assert Cad.get_session!(owner, session.id).title == "a 30 mm cube"

    # stage events arrived, ending in turn_done
    assert_receive %{event: "llm_started"}
    assert_receive %{event: "llm_done"}
    assert_receive %{event: "exec_started"}
    assert_receive %{event: "exec_done"}
    assert_receive %{event: "turn_done", payload: payload}
    assert payload.ok
    assert payload.artifacts.model_id == "abcdef0123456789"

    # engine got the extracted code
    assert hd(EngineFake.calls()).code == "part = Box(30, 30, 30)"
    # execution is scoped to the owner's directory namespace
    assert hd(EngineFake.calls()).owner_id == owner
  end

  test "first exec fails -> exactly one repair succeeds (repaired: true)", %{session: session} do
    LLMFake.set_script([
      llm_ok("```python\npart = Box(1, 1, 1)\n```"),
      llm_ok("Fixed.\n```python\npart = Box(30, 30, 30)\n```")
    ])

    EngineFake.set_script([
      %{
        ok: false,
        stage: :exec,
        error: "RuntimeError: BuildPart doesn't have a Helix object or operation",
        artifacts: nil,
        mesh: nil,
        exec_ms: 100
      },
      ok_worker("1111111111111111")
    ])

    result = run_turn(session)

    assert result.ok
    assert result.repaired
    assert result.code_failed == "part = Box(1, 1, 1)"
    assert result.artifacts.model_id == "1111111111111111"
    assert result.error == nil

    # the repair LLM call saw the failed attempt as assistant history
    repair_call = hd(Enum.drop(LLMFake.calls(), 1))
    assert %{role: :assistant, content: c} = List.last(repair_call.history)
    assert c =~ "part = Box(1, 1, 1)"
  end

  test "static-check rejection triggers repair without executing first code", %{session: session} do
    LLMFake.set_script([
      llm_ok("```python\nimport os\npart = Box(1,1,1)\n```"),
      llm_ok("```python\nfrom build123d import *\nimport math\npart = Box(2,2,2)\n```")
    ])

    EngineFake.set_script([
      %{
        ok: false,
        stage: :static_check,
        error: "import not allowed: os (only build123d and math)",
        artifacts: nil,
        mesh: nil,
        exec_ms: 0
      },
      ok_worker("2222222222222222")
    ])

    result = run_turn(session)
    assert result.ok
    assert result.repaired
  end

  test "both attempts fail: ok false with error headline", %{session: session} do
    LLMFake.set_script([
      llm_ok("```python\npart = Box(1, 1, 1)\n```"),
      llm_ok("```python\npart = Box(1, 1, 2)\n```")
    ])

    EngineFake.set_script([
      %{
        ok: false,
        stage: :exec,
        error: "ValueError: bad geometry\nmore context",
        artifacts: nil,
        mesh: nil,
        exec_ms: 10
      },
      %{
        ok: false,
        stage: :exec,
        error: "ValueError: still bad",
        artifacts: nil,
        mesh: nil,
        exec_ms: 10
      }
    ])

    result = run_turn(session)
    refute result.ok
    assert result.error == "ValueError: still bad"
    assert result.error_detail =~ "still bad"
    assert result.code == "part = Box(1, 1, 2)"
    assert result.code_failed == "part = Box(1, 1, 1)"
    assert Cad.latest_model(session.id) == nil
  end

  test "code_missing: conversational reply, no engine call", %{session: session} do
    LLMFake.set_script([llm_ok("A screw is a fastener with a helical ridge.")])

    result = run_turn(session)

    assert result.ok
    assert result.code_missing
    assert result.artifacts == nil
    assert EngineFake.calls() == []
    assert Cad.list_messages(session.id) |> length() == 2
  end

  test "truncated reply -> truncated repair message -> success", %{session: session} do
    LLMFake.set_script([
      {:ok,
       %{reply: "Here it is:\n```python\npart = Box(1, 1", reasoning: "", finish_reason: :length}},
      llm_ok("```python\npart = Box(30, 30, 30)\n```")
    ])

    EngineFake.set_script([ok_worker("3333333333333333")])

    result = run_turn(session)

    assert result.ok
    repair_call = hd(Enum.drop(LLMFake.calls(), 1))
    assert repair_call.message =~ "cut off before the ```python code block finished"
    assert repair_call.message =~ "part = Box(1, 1"
  end

  test "LLM error short-circuits (no exec, no repair)", %{session: session} do
    LLMFake.set_script([{:error, "LLM API returned HTTP 429: quota"}])

    result = run_turn(session)

    refute result.ok
    assert result.error == "LLM API returned HTTP 429: quota"
    assert EngineFake.calls() == []
    assert length(LLMFake.calls()) == 1
  end

  test "repair budget skip: slow model keeps the first error", %{session: session} do
    # force the turn to look already over budget
    cfg =
      Mnft.Cad.Config.all()
      |> Keyword.put(
        :llm,
        Keyword.put(
          Mnft.Cad.Config.llm(),
          :repair_max_elapsed_s,
          -1
        )
      )

    Application.put_env(:mnft_cad, :cad, cfg)

    on_exit(fn ->
      Application.put_env(
        :mnft_cad,
        :cad,
        Keyword.put(cfg, :llm, Keyword.put(cfg[:llm], :repair_max_elapsed_s, 240))
      )
    end)

    LLMFake.set_script([llm_ok("```python\npart = Box(1, 1, 1)\n```")])

    EngineFake.set_script([
      %{
        ok: false,
        stage: :exec,
        error: "RuntimeError: boom",
        artifacts: nil,
        mesh: nil,
        exec_ms: 1
      }
    ])

    result = run_turn(session)

    refute result.ok
    assert result.error =~ "the model was too slow on this attempt"
    assert result.error =~ "RuntimeError: boom"
    assert length(LLMFake.calls()) == 1
  end

  test "photo turn routes to the vision model and repeats photos on repair", %{session: session} do
    photo = %{data_url: "data:image/png;base64," <> Base.encode64("png"), label: "reference"}

    LLMFake.set_script([
      llm_ok("```python\npart = Box(1,1,1)\n```"),
      llm_ok("```python\nfrom build123d import *\nimport math\npart = Box(3,3,3)\n```")
    ])

    EngineFake.set_script([
      %{ok: false, stage: :exec, error: "boom", artifacts: nil, mesh: nil, exec_ms: 1},
      ok_worker("4444444444444444")
    ])

    result = Turn.run(session.id, session.owner_id, "model this part", [photo], %{})

    assert result.ok
    assert result.meta.vision
    assert result.meta.model == "test-vision"

    [first, repair] = LLMFake.calls()
    assert first.vision?
    assert length(first.images) == 1
    # repair repeats the same images
    assert repair.images == first.images

    # only metadata persisted, never bytes
    user_msg = Cad.list_messages(session.id) |> hd()

    assert user_msg.meta["photos"] == [
             %{"label" => "reference", "media_type" => "image/png", "bytes" => 3}
           ]
  end

  test "datasheet URL turn: fetched page joins images, enriches the prompt, vision model wins", %{
    session: session
  } do
    LLMFake.set_script([llm_ok("```python\npart = Box(427, 30, 30)\n```")])
    EngineFake.set_script([ok_worker()])

    message = "Model this rails https://example.com/z-rails.pdf, length 84HP"
    result = Turn.run(session.id, session.owner_id, message, [], %{})

    assert result.ok
    assert result.meta.vision
    assert result.meta.model == "test-vision"

    call = hd(LLMFake.calls())
    assert call.message =~ "[Reference datasheet https://example.com/z-rails.pdf — 1 page(s)"
    assert call.message =~ "84 HP = 427 mm"
    assert [%{label: "reference", media_type: "image/png"}] = call.images
    assert call.vision?

    # fetch stage events, in order, before the LLM
    assert_receive %{event: "fetch_started", payload: %{count: 1}}
    assert_receive %{event: "fetch_done", payload: %{fetched: 1, pages: 1, failed: []}}
    assert_receive %{event: "llm_started"}

    # persisted: original content, references in meta, page in photos meta
    user_msg = Cad.list_messages(session.id) |> hd()
    assert user_msg.content == message

    assert user_msg.meta["references"] == [
             %{
               "url" => "https://example.com/z-rails.pdf",
               "pages" => 1,
               "text" => "Tiptop z-rails: 84 HP = 427 mm length, 23.8 mm deep"
             }
           ]

    assert user_msg.meta["photos"] == [
             %{"label" => "reference", "media_type" => "image/png", "bytes" => 4}
           ]
  end

  test "non-PDF reference stays a text turn: skip leaves message untouched", %{session: session} do
    # ReferencesFake only handles URLs; a URL-less message exercises the
    # no-reference passthrough: no fetch events, text model, no images.
    LLMFake.set_script([llm_ok("Sure.")])

    result = Turn.run(session.id, session.owner_id, "what dimensions fit 84HP?", [], %{})

    assert result.ok
    refute result.meta.vision
    assert result.meta.model == "test-text"
    assert hd(LLMFake.calls()).message == "what dimensions fit 84HP?"
    assert hd(LLMFake.calls()).images == []
    user_msg = Cad.list_messages(session.id) |> hd()
    assert user_msg.meta["references"] == []
    refute_receive %{event: "fetch_started"}
  end

  test "photo-less follow-up carries the previous photos as \"earlier\" (prompt-only)", %{
    session: session
  } do
    photo = %{data_url: "data:image/png;base64," <> Base.encode64("png"), label: "reference"}

    LLMFake.set_script([
      llm_ok("```python\npart = Box(30,30,30)\n```"),
      llm_ok("```python\npart = Box(60,30,30)\n```")
    ])

    EngineFake.set_script([
      ok_worker(),
      %{
        ok: true,
        stage: :exec,
        error: nil,
        artifacts: %{model_id: "2222222222222222", stl: "/tmp/x", step: "/tmp/x", glb: nil},
        mesh: %{"triangles" => 24, "bbox_mm" => [60.0, 30.0, 30.0], "volume_mm3" => 54_000.0},
        exec_ms: 1
      }
    ])

    Turn.run(session.id, session.owner_id, "a cube", [photo], %{})
    result = Turn.run(session.id, session.owner_id, "make it bigger", [], %{})

    assert result.ok
    assert result.meta.vision
    assert result.meta.model == "test-vision"

    [first, second] = LLMFake.calls()
    assert first.vision?
    [%{label: "earlier"}] = second.images
    assert second.vision?

    # carried photos are prompt-only: journal shows none for the carry turn
    user_msgs = Cad.list_messages(session.id) |> Enum.filter(&(&1.role == :user))
    assert Enum.at(user_msgs, 1).meta["photos"] == []
    assert Enum.at(user_msgs, 1).meta["references"] == []
  end

  test "a turn with its own photos does not receive carried images", %{session: session} do
    p1 = %{data_url: "data:image/png;base64," <> Base.encode64("p1"), label: "reference"}
    p2 = %{data_url: "data:image/png;base64," <> Base.encode64("p2"), label: "current"}

    LLMFake.set_script([
      llm_ok("```python\npart = Box(30,30,30)\n```"),
      llm_ok("```python\npart = Box(90,30,30)\n```")
    ])

    EngineFake.set_script([
      ok_worker(),
      %{
        ok: true,
        stage: :exec,
        error: nil,
        artifacts: %{model_id: "3333333333333333", stl: "/tmp/x", step: "/tmp/x", glb: nil},
        mesh: %{"triangles" => 48, "bbox_mm" => [90.0, 30.0, 30.0], "volume_mm3" => 81_000.0},
        exec_ms: 1
      }
    ])

    Turn.run(session.id, session.owner_id, "first", [p1], %{})
    Turn.run(session.id, session.owner_id, "second", [p2], %{})

    [first, second] = LLMFake.calls()
    assert length(first.images) == 1
    assert length(second.images) == 1
    assert hd(second.images).label == "current"
    refute hd(second.images).label == "earlier"
  end

  test "invalid photo short-circuits with the validator's message", %{session: session} do
    bad = [%{data_url: "data:image/gif;base64," <> Base.encode64("GIF"), label: "reference"}]

    result = Turn.run(session.id, session.owner_id, "model this", bad, %{})

    refute result.ok
    assert result.error =~ "unsupported media type image/gif"
    assert EngineFake.calls() == []
  end

  describe "noop re-ask (identical geometry)" do
    setup %{session: session} do
      {:ok, _} =
        Cad.record_turn(
          session,
          %{content: "make the first part", meta: %{}},
          %{content: "Here is v1.", code: "part = Box(9, 9, 3) - internal", meta: %{}},
          %{
            id: "prevmodel00000001",
            mesh: %{"bbox_mm" => [9.4, 9.4, 3.0], "triangles" => 128, "volume_mm3" => 98.2},
            has_glb: true
          }
        )

      :ok
    end

    defp same_mesh_worker(model_id) do
      %{
        ok: true,
        stage: :exec,
        error: nil,
        artifacts: %{
          model_id: model_id,
          stl: "/tmp/x/model.stl",
          step: "/tmp/x/model.step",
          glb: nil
        },
        mesh: %{"bbox_mm" => [9.4, 9.4, 3.0], "triangles" => 128, "volume_mm3" => 98.2},
        exec_ms: 100
      }
    end

    test "identical geometry re-asks once; the second reply's code wins", %{session: session} do
      LLMFake.set_script([
        llm_ok("Removed the hole.\n```python\npart = Box(9, 9, 3) - internal\n```"),
        llm_ok(
          "Changes:\n- removed the `body - internal` square cutout\n```python\npart = Box(9, 9, 3)\n```"
        )
      ])

      changed = %{
        same_mesh_worker("newmodel00000002")
        | mesh: %{"bbox_mm" => [9.4, 9.4, 3.0], "triangles" => 96, "volume_mm3" => 130.0}
      }

      EngineFake.set_script([same_mesh_worker("newmodel00000001"), changed])

      result = Turn.run(session.id, session.owner_id, "remove the cutout", [], %{})

      assert result.ok
      assert result.code == "part = Box(9, 9, 3)"
      assert result.mesh["volume_mm3"] == 130.0

      assert [%{message: first_message}, recheck] = LLMFake.calls()
      assert first_message == "remove the cutout"
      assert recheck.message =~ "identical"
      assert recheck.message =~ ~s("remove the cutout")
      assert recheck.message =~ "Current model: bbox 9.4 x 9.4 x 3 mm"

      assert List.last(recheck.history) == %{
               role: :assistant,
               content: "Removed the hole.\n```python\npart = Box(9, 9, 3) - internal\n```"
             }

      # the second exec ran the re-ask's code
      assert List.last(EngineFake.calls()).code == "part = Box(9, 9, 3)"

      # persisted: code B + noop_retried meta + the changed model
      assert_receive %{event: "llm_started", payload: %{noop: true}}
      assert_receive %{event: "llm_done", payload: %{noop: true}}
      assert_receive %{event: "exec_started", payload: %{noop: true}}
      assert_receive %{event: "turn_done", payload: %{ok: true}}

      assistant = Cad.list_messages(session.id) |> List.last()
      assert assistant.code == "part = Box(9, 9, 3)"
      assert assistant.meta["noop_retried"] == true

      model = Cad.latest_model(session.id)
      assert model.id == "newmodel00000002"
      assert model.mesh["volume_mm3"] == 130.0
    end

    test "kept as-is: repeated code re-executes, result unchanged, noop_retried true", %{
      session: session
    } do
      LLMFake.set_script([
        llm_ok("```python\npart = Box(9, 9, 3)\n```"),
        llm_ok("Keeping the model exactly as-is.\n```python\npart = Box(9, 9, 3)\n```")
      ])

      EngineFake.set_script([
        same_mesh_worker("newmodel00000001"),
        same_mesh_worker("newmodel00000002")
      ])

      result = Turn.run(session.id, session.owner_id, "render it again exactly the same", [], %{})

      assert result.ok
      assert result.code == "part = Box(9, 9, 3)"
      assert result.mesh["volume_mm3"] == 98.2
      assert length(LLMFake.calls()) == 2

      assistant = Cad.list_messages(session.id) |> List.last()
      assert assistant.meta["noop_retried"] == true
    end

    test "failed re-ask keeps the first valid result (never regress)", %{session: session} do
      LLMFake.set_script([
        llm_ok("```python\npart = Box(9, 9, 3)\n```"),
        llm_ok("```python\npart = Box(9, 9, 4)\n```")
      ])

      EngineFake.set_script([
        same_mesh_worker("newmodel00000001"),
        %{ok: false, stage: :exec, error: "boom", artifacts: nil, mesh: nil, exec_ms: 5}
      ])

      result = Turn.run(session.id, session.owner_id, "remove the cutout", [], %{})

      assert result.ok
      assert result.code == "part = Box(9, 9, 3)"
      assert result.mesh["volume_mm3"] == 98.2
      assert result.error == nil

      assistant = Cad.list_messages(session.id) |> List.last()
      assert assistant.meta["noop_retried"] == true
      # the extra re-ask time still lands in the accounting
      assert assistant.meta["exec_ms"] > 0
      assert Cad.latest_model(session.id).id == "newmodel00000001"
    end

    test "no previous model: exactly one LLM call, noop_retried false" do
      # brand-new session: nothing persisted, so no re-ask can trigger
      owner = "owner-" <> Integer.to_string(System.unique_integer([:positive]))
      {:ok, fresh} = Cad.create_session(owner)

      LLMFake.set_script([llm_ok("```python\npart = Box(9, 9, 3)\n```")])
      EngineFake.set_script([same_mesh_worker("newmodel00000001")])

      result = Turn.run(fresh.id, fresh.owner_id, "make a plate", [], %{})

      assert result.ok
      assert length(LLMFake.calls()) == 1
      assert length(EngineFake.calls()) == 1

      assistant = Cad.list_messages(fresh.id) |> List.last()
      assert assistant.meta["noop_retried"] == false
    end

    test "different geometry: no re-ask", %{session: session} do
      LLMFake.set_script([llm_ok("Taller now.\n```python\npart = Box(9, 9, 6)\n```")])

      taller = %{
        same_mesh_worker("newmodel00000001")
        | mesh: %{"bbox_mm" => [9.4, 9.4, 6.0], "triangles" => 128, "volume_mm3" => 196.4}
      }

      EngineFake.set_script([taller])

      result = Turn.run(session.id, session.owner_id, "make it 3 mm taller", [], %{})

      assert result.ok
      assert length(LLMFake.calls()) == 1

      assistant = Cad.list_messages(session.id) |> List.last()
      assert assistant.meta["noop_retried"] == false
    end
  end

  test "agent stays idle-able: turn.finish after completion, second request works", %{
    session: session
  } do
    LLMFake.set_script([llm_ok("```python\npart = Box(5,5,5)\n```")])
    EngineFake.set_script([ok_worker("5555555555555555")])

    assert {:ok, :started} = Sessions.request_turn(session, "a 30 mm cube", [], %{})
    assert_receive %{event: "turn_done"}, 3000

    # turn.finish is a cast sent after turn_done; poll until processed
    server = Sessions.whereis(session.id)

    status =
      Enum.find_value(1..100, fn _ ->
        {:ok, state} = Jido.AgentServer.state(server)

        if state.agent.state.status == :idle,
          do: :idle,
          else: Process.sleep(20) && nil
      end)

    assert status == :idle
  end

  test "turn_info reports the in-flight turn and resets after it finishes", %{
    session: session
  } do
    # No agent server yet
    assert Sessions.turn_info(session.id) == %{
             running: false,
             started_ms: 0,
             message: nil,
             photos: []
           }

    LLMFake.set_script([{:hold, llm_ok("```python\npart = Box(30,30,30)\n```")}])
    EngineFake.set_script([ok_worker()])

    assert {:ok, :started} = Sessions.request_turn(session, "a 30 mm cube", [], %{})

    assert Enum.find_value(1..100, fn _ ->
             if LLMFake.held() != [], do: :held, else: Process.sleep(20) && nil
           end)

    info = Sessions.turn_info(session.id)
    assert info.running == true
    assert info.started_ms > 0
    assert info.message == "a 30 mm cube"
    assert info.photos == []

    LLMFake.release(hd(LLMFake.held()))
    assert_receive %{event: "turn_done"}, 3000

    # turn.finish is a cast; poll until the agent processed it
    assert Enum.find_value(1..100, fn _ ->
             if Sessions.turn_info(session.id).running == false,
               do: :idle,
               else: Process.sleep(20) && nil
           end)

    assert Sessions.turn_info(session.id).message == nil
  end

  test "busy session rejects a second turn (action contract)", %{session: session} do
    params = %{
      session_id: session.id,
      owner_id: session.owner_id,
      message: "second",
      photos: [],
      current: %{}
    }

    # a session already generating refuses a new turn without spawning
    assert {:error, reason} =
             Mnft.Cad.Actions.TurnStart.run(params, %{state: %{status: :generating}})

    assert reason =~ "already running"
    assert EngineFake.calls() == []
    assert LLMFake.calls() == []
  end

  test "request_turn accepts client JSON maps (string keys) for photos and current", %{
    session: session
  } do
    png = "data:image/png;base64," <> Base.encode64("png")
    photos = [%{"data_url" => png, "label" => "reference"}]
    current = %{"bbox_mm" => [30.0, 30.0, 30.0], "triangles" => 12, "volume_mm3" => 27_000.0}

    LLMFake.set_script([llm_ok("```python\npart = Box(1,1,1)\n```")])
    EngineFake.set_script([ok_worker()])

    assert {:ok, :started} = Sessions.request_turn(session, "model this part", photos, current)
    assert_receive %{event: "turn_done"}, 3000

    [call] = LLMFake.calls()
    assert call.vision?
    assert length(call.images) == 1
    # current reaches the prompt unchanged: current_model_line matches string keys
    assert call.current == current
  end

  test "request_turn returns an error when TurnStart rejects the params", %{session: session} do
    assert {:error, _msg} = Sessions.request_turn(session, "x", ["not-a-map"], %{})
    refute_receive %{event: "turn_started"}
    refute_receive %{event: "turn_done"}, 100
    assert EngineFake.calls() == []
    assert LLMFake.calls() == []
  end
end

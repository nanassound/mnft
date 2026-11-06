defmodule MnftOcex.EngineTest do
  use ExUnit.Case, async: false

  alias MnftOcex.Engine

  test "the dialect tag routes prompts to the ocex prompt" do
    assert Engine.dialect() == :ocex
  end

  test "healthy? is true when the NIF and toolkit load" do
    assert Engine.healthy?() == true
  end

  test "execute returns the full engine contract for the golden plate" do
    run = Engine.execute(MnftOcex.TestPrograms.bore_plate_json(), "engine-test-owner")

    assert run.ok, "expected ok, got: #{inspect(run.error)}"
    assert run.stage == :exec
    assert run.error == nil
    assert is_integer(run.exec_ms) and run.exec_ms >= 0

    assert %{triangles: triangles, bbox_mm: bbox, volume_mm3: vol} = run.mesh
    assert triangles > 0
    assert length(bbox) == 3
    assert_in_delta vol, MnftOcex.TestPrograms.bore_plate_volume(), vol * 2.0e-3

    art = run.artifacts
    assert art.model_id =~ ~r/^[0-9a-f]{32}$/
    assert File.exists?(art.stl)
    assert File.stat!(art.stl).size > 0
    assert File.exists?(art.step)
    assert File.stat!(art.step).size > 0
    assert File.exists?(art.script)
    assert art.script =~ "model.ocex.json"
    # GLB is best-effort; assert only that the key exists.
    assert Map.has_key?(art, :glb)
  end

  test "malformed JSON fails at static_check" do
    run = Engine.execute("{not json", "engine-test-owner")
    assert run.ok == false
    assert run.stage == :static_check
    assert run.error =~ "invalid JSON"
    assert run.artifacts == nil and run.mesh == nil
  end

  test "an unknown op fails at static_check without touching the kernel" do
    run = Engine.execute(~s({"ops": [{"op": "gear", "n": 12}]}), "engine-test-owner")
    assert run.ok == false
    assert run.stage == :static_check
    assert run.error =~ "unknown op"
  end

  test "a geometric failure (one-sided cut) fails at exec with an op index" do
    json = Jason.encode!(%{"ops" => [%{"op" => "box", "size" => [10, 10, 10]}, %{"op" => "cut"}]})
    run = Engine.execute(json, "engine-test-owner")
    assert run.ok == false
    assert run.stage == :exec
    assert run.error =~ "op 2"
  end

  test "a program ending with two shapes fails at exec" do
    json =
      Jason.encode!(%{
        "ops" => [%{"op" => "box", "size" => [1, 1, 1]}, %{"op" => "box", "size" => [2, 2, 2]}]
      })

    run = Engine.execute(json, "engine-test-owner")
    assert run.ok == false
    assert run.stage == :exec
    assert run.error =~ "exactly one shape"
  end

  # --- prompt-shaped programs end to end (review fixes B2/M1/M2/M4) -------------

  test "a prompt-shaped polygon + extrude (no dir) runs through the engine" do
    code = ~s({"ops":[{"op":"polygon","n":6,"r":10},{"op":"extrude","h":5}]})
    run = Engine.execute(code, "engine-test-owner")

    assert run.ok, "expected ok, got: #{inspect(run.error)}"
    # Regular hexagon: 6 triangles of area (1/2) r^2 sin(2 pi / 6), extruded 5 mm.
    expected = 6 * 0.5 * 100 * :math.sin(2 * :math.pi() / 6) * 5
    assert_in_delta run.mesh.volume_mm3, expected, expected * 0.01
    assert run.artifacts.script =~ "model.ocex.json"
    assert File.exists?(run.artifacts.script)
  end

  test "a non-vector \"at\" on a primitive fails at static_check, not exec" do
    run = Engine.execute(~s({"ops":[{"op":"box","size":[1,1,1],"at":"bad"}]}), "engine-test-owner")

    assert run.ok == false
    assert run.stage == :static_check
    assert run.error =~ "\"at\""
  end

  test "a prism with a non-numeric rot fails at static_check" do
    code = ~s({"ops":[{"op":"prism","n":6,"r":10,"h":5,"rot":"x"}]})
    run = Engine.execute(code, "engine-test-owner")

    assert run.ok == false
    assert run.stage == :static_check
    assert run.error =~ "\"rot\""
  end

  describe "wall-clock bound" do
    setup do
      prior = Application.get_env(:mnft_cad, :cad)
      on_exit(fn -> Application.put_env(:mnft_cad, :cad, prior) end)
      Application.put_env(:mnft_cad, :cad, Keyword.put(prior, :exec_timeout_s, 1))
      :ok
    end

    test "a caller queued behind a saturated limiter times out, and no permit leaks" do
      parent = self()
      capacity = Mnft.Cad.Config.get(:exec_concurrency)

      holders =
        for n <- 1..capacity do
          spawn_link(fn ->
            Mnft.Cad.ExecLimiter.run(fn ->
              send(parent, {:holding, n})

              receive do
                :release -> :ok
              end
            end)
          end)
        end

      for n <- 1..capacity, do: assert_receive({:holding, ^n}, 5_000)

      code = ~s({"ops":[{"op":"box","size":[1,1,1]}]})
      run = Engine.execute(code, "engine-test-owner")

      assert run.ok == false
      assert run.stage == :exec
      assert run.error =~ "wall clock"
      assert run.exec_ms >= 900

      for pid <- holders, do: send(pid, :release)

      # Every permit is back: the engine runs again at once.
      assert Engine.execute(code, "engine-test-owner").ok
    end
  end
end

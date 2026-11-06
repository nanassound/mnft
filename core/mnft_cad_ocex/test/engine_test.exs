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
end

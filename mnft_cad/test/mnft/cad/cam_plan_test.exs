defmodule Mnft.Cad.CamPlanTest do
  use ExUnit.Case, async: true

  alias Mnft.Cad.CamPlan
  alias Mnft.Cad.CodeGen

  # the real vendored config — validator and file must stay in sync
  defp toolbits do
    {:ok, tools} = CamPlan.toolbits()
    tools
  end

  describe "toolbits/0" do
    test "loads the vendored config with machine block and ids" do
      assert {:ok, %{"machine" => %{"post" => "grbl", "work_envelope_mm" => env}, "toolbits" => tools}} =
               CamPlan.toolbits()

      assert length(env) == 3
      assert Map.has_key?(tools, "flat-3.175")
      assert Map.has_key?(tools, "ball-0.8")
      assert Map.has_key?(tools, "vbit-20")
      # MC40A flat sizes + ball equivalents + vbit
      assert map_size(tools) == 23
    end

    test "every fctb reference exists on disk" do
      {:ok, %{"toolbits" => tools}} = CamPlan.toolbits()
      dir = CamPlan.toolbits_path() |> Path.dirname() |> Path.join("toolbits")

      for {_id, spec} <- tools do
        assert File.exists?(Path.join(dir, spec["fctb"])), "missing #{spec["fctb"]}"
        assert spec["feeds"]["wood"] && spec["feeds"]["aluminum"]
      end
    end
  end

  describe "validate/2" do
    test "accepts a minimal valid plan" do
      plan = %{"material" => "wood", "ops" => [%{"op" => "profile", "toolbit" => "flat-3.175"}]}
      assert {:ok, ^plan} = CamPlan.validate(plan, toolbits())
    end

    test "accepts drill op with positive peck_mm" do
      plan = %{
        "material" => "aluminum",
        "ops" => [%{"op" => "drill", "toolbit" => "flat-3.175", "peck_mm" => 2.0}]
      }

      assert {:ok, _} = CamPlan.validate(plan, toolbits())
    end

    test "rejects non-object plans" do
      assert {:error, msg} = CamPlan.validate("wood", toolbits())
      assert msg =~ "material"
      assert {:error, _} = CamPlan.validate(%{}, toolbits())
    end

    test "rejects unknown material" do
      plan = %{"material" => "steel", "ops" => [%{"op" => "profile", "toolbit" => "flat-3.175"}]}
      assert {:error, msg} = CamPlan.validate(plan, toolbits())
      assert msg =~ "material must be one of wood, aluminum"
    end

    test "rejects empty ops" do
      plan = %{"material" => "wood", "ops" => []}
      assert {:error, msg} = CamPlan.validate(plan, toolbits())
      assert msg =~ "ops must not be empty"
    end

    test "rejects non-list ops" do
      assert {:error, _} = CamPlan.validate(%{"material" => "wood", "ops" => "face"}, toolbits())
      assert {:error, _} = CamPlan.validate(%{"material" => "wood"}, toolbits())
    end

    test "rejects unknown op types" do
      plan = %{"material" => "wood", "ops" => [%{"op" => "vcarve", "toolbit" => "vbit-20"}]}
      assert {:error, "op 1: 'op' must be one of face, pocket, profile, drill; got \"vcarve\""} =
               CamPlan.validate(plan, toolbits())
    end

    test "rejects unknown toolbit ids" do
      plan = %{"material" => "wood", "ops" => [%{"op" => "face", "toolbit" => "flat-9.9"}]}
      assert {:error, "op 1: unknown toolbit \"flat-9.9\""} = CamPlan.validate(plan, toolbits())
    end

    test "rejects unknown op keys (strict schema)" do
      plan = %{
        "material" => "wood",
        "ops" => [%{"op" => "face", "toolbit" => "flat-3.175", "stepover" => 0.4}]
      }

      assert {:error, msg} = CamPlan.validate(plan, toolbits())
      assert msg =~ "unknown keys"
    end

    test "rejects non-positive peck_mm" do
      for peck <- [0, -1, "deep"] do
        plan = %{
          "material" => "wood",
          "ops" => [%{"op" => "drill", "toolbit" => "flat-2.0", "peck_mm" => peck}]
        }

        assert {:error, msg} = CamPlan.validate(plan, toolbits())
        assert msg =~ "peck_mm"
      end
    end

    test "error names the offending op index" do
      plan = %{
        "material" => "wood",
        "ops" => [
          %{"op" => "face", "toolbit" => "flat-3.175"},
          %{"op" => "pocket", "toolbit" => "ball-2.0"}
        ]
      }

      assert {:ok, _} = CamPlan.validate(plan, toolbits())
    end
  end

  describe "CodeGen.extract_cam_json/1" do
    test "returns :none without a cam block" do
      assert CodeGen.extract_cam_json("plain text") == :none
      assert CodeGen.extract_cam_json("```python\npart = Box(1,1,1)\n```") == :none
      assert CodeGen.extract_cam_json(nil) == :none
    end

    test "decodes the last cam block after a python block" do
      text = """
      Here you go.
      ```python
      part = Box(1, 1, 1)
      ```
      ```cam
      {"material": "wood", "ops": [{"op": "profile", "toolbit": "flat-3.175"}]}
      ```
      """

      assert {:ok, %{"material" => "wood"}} = CodeGen.extract_cam_json(text)
    end

    test "rejects invalid JSON and non-object bodies" do
      assert {:error, msg} = CodeGen.extract_cam_json("```cam\nnot json\n```")
      assert msg =~ "not valid JSON"

      assert {:error, msg} = CodeGen.extract_cam_json("```cam\n[1, 2]\n```")
      assert msg =~ "JSON object"
    end
  end
end

defmodule Mnft.Cad.PromptOpenscadTest do
  use ExUnit.Case, async: false

  alias Mnft.Cad.{Prompt, PromptOpenscad}

  # Greppable text assertions only: they pin what the prompt SAYS, they cannot
  # prove the model obeys it (that needs a live turn).

  describe "system/0" do
    test "returns a non-empty string" do
      s = PromptOpenscad.system()
      assert is_binary(s) and String.length(s) > 100
    end

    test "names OpenSCAD before any other library and forbids Python imports" do
      s = PromptOpenscad.system()
      {osc_at, _} = :binary.match(s, "OpenSCAD")
      {py_at, _} = :binary.match(s, "Python")
      assert osc_at < py_at
      assert s =~ "NOT Python"
      refute s =~ "from build123d"
      refute s =~ "from smlibpy"
    end

    test "carries the static-check contracts" do
      s = PromptOpenscad.system()
      assert s =~ "import("
      assert s =~ "surface("
      assert s =~ "part"
    end

    test "carries the mm units requirement" do
      assert PromptOpenscad.system() =~ "millimetre"
    end

    test "is NOT byte-identical to Prompt.system/0 (build123d)" do
      refute PromptOpenscad.system() == Prompt.system()
    end
  end

  describe "skills_block/0" do
    test "includes the quickref skill" do
      block = PromptOpenscad.skills_block()
      assert block =~ "OpenSCAD skills"
      assert block =~ "Do not write Python"
    end

    test "returns \"\" when the dir is missing" do
      prev = Application.get_env(:mnft_cad, :cad_skills_openscad_dir)
      Application.put_env(:mnft_cad, :cad_skills_openscad_dir, "/nonexistent/openscad-skills")

      on_exit(fn -> restore(prev) end)

      assert PromptOpenscad.skills_block() == ""
    end

    defp restore(nil), do: Application.delete_env(:mnft_cad, :cad_skills_openscad_dir)
    defp restore(v), do: Application.put_env(:mnft_cad, :cad_skills_openscad_dir, v)
  end
end

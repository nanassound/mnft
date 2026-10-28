defmodule Mnft.Cad.PromptTest do
  use ExUnit.Case, async: false

  alias Mnft.Cad.Prompt

  describe "skills_block/0" do
    test "concatenates .md files sorted by filename, wrapped in the header" do
      tmp = Path.join(System.tmp_dir!(), "cad_skills_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "02-b.md"), "second skill\n")
      File.write!(Path.join(tmp, "01-a.md"), "first skill\n")
      File.write!(Path.join(tmp, "ignored.txt"), "not markdown")

      Application.put_env(:mnft_cad, :cad_skills_dir, tmp)

      on_exit(fn ->
        Application.delete_env(:mnft_cad, :cad_skills_dir)
        File.rm_rf!(tmp)
      end)

      block = Prompt.skills_block()

      assert block =~ "# build123d skills (maintained as markdown under priv/cad/skills)"
      assert block =~ "first skill"
      assert block =~ "second skill"
      refute block =~ "not markdown"
      # 01- before 02-
      assert String.split(block, ["first skill", "second skill"]) == [
               "\n\n# build123d skills (maintained as markdown under priv/cad/skills)\n\n",
               "\n\n---\n\n",
               "\n"
             ]
    end

    test "missing dir returns empty string" do
      Application.put_env(
        :mnft_cad,
        :cad_skills_dir,
        Path.join(System.tmp_dir!(), "cad_skills_missing_#{System.unique_integer([:positive])}")
      )

      on_exit(fn -> Application.delete_env(:mnft_cad, :cad_skills_dir) end)

      assert Prompt.skills_block() == ""
    end

    test "shipped priv/cad/skills files reach the system prompt" do
      Application.delete_env(:mnft_cad, :cad_skills_dir)

      system = Prompt.system() <> Prompt.skills_block()

      assert system =~ "# build123d quick reference"
      assert system =~ "# Subtracted features"
      assert system =~ "# 2D before 3D"
      assert system =~ "# Sketch planes and object selection"
      # skills come after the ported system prompt
      assert system =~ ~r/Iteration discipline[\s\S]*# Subtracted features/
    end
  end
end

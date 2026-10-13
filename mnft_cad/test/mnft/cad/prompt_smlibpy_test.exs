defmodule Mnft.Cad.PromptSmlibpyTest do
  use ExUnit.Case, async: false

  alias Mnft.Cad.{Prompt, PromptSmlibpy}

  # -------------------------------------------------------------------------
  # system/0 content checks
  # -------------------------------------------------------------------------

  describe "system/0" do
    test "returns a non-empty string" do
      assert is_binary(PromptSmlibpy.system())
      assert String.length(PromptSmlibpy.system()) > 100
    end

    test "mentions smlibpy" do
      assert PromptSmlibpy.system() =~ "smlibpy"
    end

    test "carries the method-style fillet gotcha" do
      s = PromptSmlibpy.system()
      assert s =~ "fillet" and (s =~ "method" or s =~ "METHOD")
    end

    test "carries the no module-level fuse gotcha" do
      s = PromptSmlibpy.system()
      assert s =~ "fuse"
    end

    test "carries the part-binding contract" do
      assert PromptSmlibpy.system() =~ "part"
    end

    test "carries the no-export contract" do
      s = PromptSmlibpy.system()
      assert s =~ "export_stl" or s =~ "export"
    end

    test "carries the mm units requirement" do
      s = PromptSmlibpy.system()
      assert s =~ "mm" or s =~ "millimetre" or s =~ "millimeter"
    end

    test "is NOT byte-identical to Prompt.system/0 (build123d)" do
      refute PromptSmlibpy.system() == Prompt.system()
    end

    # Greppable text assertions only: they pin what the prompt SAYS, they cannot
    # prove the model obeys it (that needs a live turn).
    test "names smlibpy before any other library and opens with the import line" do
      s = PromptSmlibpy.system()
      {smlibpy_at, _} = :binary.match(s, "smlibpy")
      {b123_at, _} = :binary.match(s, "build123d")
      assert smlibpy_at < b123_at
      assert String.starts_with?(s, "You write **smlibpy** code. Your first line is exactly `from smlibpy import *`")
    end

    test "mentions build123d only to forbid it, never instructs importing it" do
      s = PromptSmlibpy.system()
      refute s =~ "from build123d"
      refute s =~ "import build123d"
      assert s =~ "Never write, import or mention `build123d`"
      assert s =~ "rejected before your code runs"
    end

    test "the always-injected gotchas skill leads with the build123d-prior trap" do
      Application.delete_env(:mnft_cad, :cad_skills_smlibpy_dir)
      block = PromptSmlibpy.skills_block()
      assert block =~ "import not allowed: build123d"
      {trap, _} = :binary.match(block, "Do not import build123d")
      {first_gotcha, _} = :binary.match(block, "## Method-style vs free functions")
      assert trap < first_gotcha
    end
  end

  # -------------------------------------------------------------------------
  # skills_block/0 — uses priv/cad/skills-smlibpy/ by default
  # -------------------------------------------------------------------------

  describe "skills_block/0" do
    test "returns non-empty string with shipped priv files" do
      Application.delete_env(:mnft_cad, :cad_skills_smlibpy_dir)
      block = PromptSmlibpy.skills_block()
      assert is_binary(block)
      assert block != ""
    end

    test "shipped files include quickref" do
      Application.delete_env(:mnft_cad, :cad_skills_smlibpy_dir)
      block = PromptSmlibpy.skills_block()
      assert block =~ "smlibpy quick reference"
    end

    test "shipped files mention Helix (threaded fastener)" do
      Application.delete_env(:mnft_cad, :cad_skills_smlibpy_dir)
      block = PromptSmlibpy.skills_block()
      assert block =~ "Helix"
    end

    test "missing dir returns empty string" do
      Application.put_env(
        :mnft_cad,
        :cad_skills_smlibpy_dir,
        Path.join(System.tmp_dir!(), "nonexistent_smlibpy_skills_#{System.unique_integer([:positive])}")
      )

      on_exit(fn -> Application.delete_env(:mnft_cad, :cad_skills_smlibpy_dir) end)

      assert PromptSmlibpy.skills_block() == ""
    end

    test "concatenates .md files sorted by filename" do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "cad_skills_smlibpy_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "02-b.md"), "second skill\n")
      File.write!(Path.join(tmp, "01-a.md"), "first skill\n")
      File.write!(Path.join(tmp, "ignored.txt"), "not markdown")

      Application.put_env(:mnft_cad, :cad_skills_smlibpy_dir, tmp)

      on_exit(fn ->
        Application.delete_env(:mnft_cad, :cad_skills_smlibpy_dir)
        File.rm_rf!(tmp)
      end)

      block = PromptSmlibpy.skills_block()

      assert block =~ "# smlibpy skills"
      assert block =~ "first skill"
      assert block =~ "second skill"
      refute block =~ "not markdown"
      # sorted: 01- before 02-
      assert String.split(block, ["first skill", "second skill"]) |> length() == 3
    end
  end

  # -------------------------------------------------------------------------
  # llm.ex routing: system_prompt/0 picks PromptSmlibpy for :smlibpy dialect
  # -------------------------------------------------------------------------

  describe "LLM system_prompt routing" do
    test "build123d engine uses Prompt.system/0" do
      original_engine = Mnft.Cad.Config.get(:engine)

      # Simulate build123d
      Application.put_env(
        :mnft_cad,
        :cad,
        Keyword.put(Mnft.Cad.Config.all(), :engine, Mnft.Cad.Engines.Build123d)
      )

      on_exit(fn ->
        Application.put_env(
          :mnft_cad,
          :cad,
          Keyword.put(Mnft.Cad.Config.all(), :engine, original_engine)
        )
      end)

      # build123d system prompt contains the build123d gotchas
      system = Prompt.system() <> Prompt.skills_block()
      assert system =~ "build123d"
    end

    test "EngineFake has no dialect/0 — falls back gracefully" do
      # EngineFake does not implement dialect/0; function_exported? must be false
      refute function_exported?(Mnft.Cad.EngineFake, :dialect, 0)
    end

    test "Smlibpy.dialect/0 is exported and returns :smlibpy" do
      Code.ensure_loaded!(Mnft.Cad.Engines.Smlibpy)
      assert function_exported?(Mnft.Cad.Engines.Smlibpy, :dialect, 0)
      assert Mnft.Cad.Engines.Smlibpy.dialect() == :smlibpy
    end

    test "Build123d.dialect/0 is exported and returns :build123d" do
      Code.ensure_loaded!(Mnft.Cad.Engines.Build123d)
      assert function_exported?(Mnft.Cad.Engines.Build123d, :dialect, 0)
      assert Mnft.Cad.Engines.Build123d.dialect() == :build123d
    end
  end
end

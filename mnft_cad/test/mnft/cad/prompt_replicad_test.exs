defmodule Mnft.Cad.PromptReplicadTest do
  use ExUnit.Case, async: false

  alias Mnft.Cad.{Prompt, PromptReplicad}

  # Greppable text assertions only: they pin what the prompt SAYS, they cannot
  # prove the model obeys it (that needs a live turn).

  defmodule ReplicadEngineStub do
    def dialect, do: :replicad
  end

  describe "system/0" do
    test "returns a non-empty string" do
      s = PromptReplicad.system()
      assert is_binary(s) and String.length(s) > 100
    end

    test "names replicad before any other library and forbids Python" do
      s = PromptReplicad.system()
      {rep_at, _} = :binary.match(s, "replicad")
      {py_at, _} = :binary.match(s, "Python")
      assert rep_at < py_at
      assert s =~ "NOT Python"
      refute s =~ "from build123d"
      refute s =~ "from smlibpy"
    end

    test "carries the part-binding contract and js fencing" do
      s = PromptReplicad.system()
      assert s =~ "part"
      assert s =~ "```js"
      assert s =~ "`result`, `assembly` or `obj`"
    end

    test "carries the import rule (replicad only, pre-bound)" do
      s = PromptReplicad.system()
      assert s =~ ~s("replicad")
      assert s =~ "pre-bound"
    end

    test "carries the destructive-translate gotcha" do
      assert PromptReplicad.system() =~ "DESTRUCTIVE"
    end

    test "carries the circumradius conversion for across-flats" do
      assert PromptReplicad.system() =~ "across / 2 / Math.cos(pi / 6)"
    end

    test "carries the volume measurement contract" do
      assert PromptReplicad.system() =~ "measureShapeVolumeProperties"
    end

    test "carries the mm units requirement" do
      assert PromptReplicad.system() =~ "millimetre"
    end

    test "is NOT byte-identical to Prompt.system/0 (build123d)" do
      refute PromptReplicad.system() == Prompt.system()
    end
  end

  describe "skills_block/0" do
    test "is compile-time embedded from the shipped priv files and non-empty" do
      block = PromptReplicad.skills_block()
      assert is_binary(block)
      assert block != ""
      assert block =~ "replicad skills"
    end

    test "carries the production gotcha ledger" do
      block = PromptReplicad.skills_block()
      assert block =~ "translate"
      assert block =~ "CIRCUMRADIUS"
      assert block =~ "measureShapeVolumeProperties"
      assert block =~ "sketchPolysides"
    end

    test "carries the static-check contract (import rule, no host access)" do
      block = PromptReplicad.skills_block()
      assert block =~ "REJECTS"
      assert block =~ "globalThis"
    end

    test "carries the worked example" do
      assert PromptReplicad.skills_block() =~ "circumRadius(acrossFlats)"
    end
  end

  # -------------------------------------------------------------------------
  # llm.ex routing: system_prompt/0 picks PromptReplicad for a :replicad engine
  # -------------------------------------------------------------------------

  describe "LLM system_prompt routing" do
    setup do
      original = Mnft.Cad.Config.get(:engine)

      on_exit(fn ->
        Application.put_env(:mnft_cad, :cad, Keyword.put(Mnft.Cad.Config.all(), :engine, original))
      end)

      :ok
    end

    test "a config engine exporting dialect/0 -> :replicad routes to PromptReplicad" do
      Application.put_env(
        :mnft_cad,
        :cad,
        Keyword.put(Mnft.Cad.Config.all(), :engine, ReplicadEngineStub)
      )

      assert Mnft.Cad.LLM.system_prompt() ==
               PromptReplicad.system() <> PromptReplicad.skills_block()
    end

    test "the routed prompt contains replicad content, not build123d content" do
      Application.put_env(
        :mnft_cad,
        :cad,
        Keyword.put(Mnft.Cad.Config.all(), :engine, ReplicadEngineStub)
      )

      system = Mnft.Cad.LLM.system_prompt()
      assert system =~ "replicad"
      refute system == Prompt.system() <> Prompt.skills_block()
    end
  end
end

defmodule Mnft.Cad.PromptOcexTest do
  use ExUnit.Case, async: false

  alias Mnft.Cad.{Prompt, PromptOcex}

  # The ocex engine lives in the optional mnft_cad_ocex pack; the core only
  # needs an engine module exporting dialect/0 to route the prompt.
  defmodule OcexEngineStub do
    def dialect, do: :ocex
  end

  describe "system/0" do
    test "describes the JSON dialect, not a Python/JS library" do
      s = PromptOcex.system()
      assert String.length(s) > 100
      assert s =~ "ocex"
      assert s =~ "```json"
      refute s =~ "from build123d"
    end

    test "is NOT byte-identical to Prompt.system/0 (build123d)" do
      refute PromptOcex.system() == Prompt.system()
    end
  end

  describe "skills_block/0" do
    test "is a non-empty string" do
      block = PromptOcex.skills_block()
      assert is_binary(block) and block != ""
    end
  end

  describe "LLM system_prompt routing" do
    setup do
      original = Mnft.Cad.Config.get(:engine)

      on_exit(fn ->
        Application.put_env(:mnft_cad, :cad, Keyword.put(Mnft.Cad.Config.all(), :engine, original))
      end)

      :ok
    end

    test "a config engine exporting dialect/0 -> :ocex routes to PromptOcex" do
      Application.put_env(
        :mnft_cad,
        :cad,
        Keyword.put(Mnft.Cad.Config.all(), :engine, OcexEngineStub)
      )

      assert Mnft.Cad.LLM.system_prompt() == PromptOcex.system() <> PromptOcex.skills_block()
    end
  end
end

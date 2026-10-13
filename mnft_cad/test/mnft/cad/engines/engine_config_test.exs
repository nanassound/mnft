defmodule Mnft.Cad.Engines.EngineConfigTest do
  @moduledoc """
  `MNFT_ENGINE` wiring, checked against the REAL config files (not a copy of
  their `case` statement). The engine mapping is duplicated in three places:

    * `mnft_cad/config/dev.exs`          -- loaded by `mix run` in dev
    * `mnft_cad_web/config/dev.exs`      -- loaded by `mix run` in dev
    * `mnft_cad_web/config/runtime.exs`  -- the one the Docker release uses

  The first two are exercised by booting `mix run --no-start` in the app with
  the env var set and printing `Mnft.Cad.Config.get(:engine)`. runtime.exs only
  executes inside a `:prod` release (it is guarded by `config_env() == :prod`),
  so `mix run` in dev never reaches it. The honest check available is to lift
  its actual `case System.get_env("MNFT_ENGINE", ...) ... end` expression out
  of the file and evaluate that, once per env value.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 180_000

  # __DIR__ = mnft_cad/test/mnft/cad/engines/ -> 5 levels up = project root
  @project_root Path.expand("../../../../../", __DIR__)

  # MIX_ENV=dev: this test itself runs under MIX_ENV=test, whose config/test.exs
  # swaps the engine for EngineFake; the child must load the dev config.
  defp engine_in(app, engine_env) do
    env = [{"MIX_ENV", "dev"}, {"MNFT_ENGINE", engine_env}]

    {out, status} =
      System.cmd(
        "mix",
        ["run", "--no-start", "-e", "IO.write(inspect(Mnft.Cad.Config.get(:engine)))"],
        cd: Path.join(@project_root, app),
        env: env,
        stderr_to_stdout: true
      )

    assert status == 0, "mix run failed in #{app}: #{out}"
    out
  end

  for app <- ["mnft_cad", "mnft_cad_web"] do
    test "#{app}/config/dev.exs maps MNFT_ENGINE=smlibpy to Engines.Smlibpy" do
      assert engine_in(unquote(app), "smlibpy") =~ "Mnft.Cad.Engines.Smlibpy"
    end

    test "#{app}/config/dev.exs maps MNFT_ENGINE=openscad and build123d" do
      assert engine_in(unquote(app), "openscad") =~ "Mnft.Cad.Engines.OpenScad"
      assert engine_in(unquote(app), "build123d") =~ "Mnft.Cad.Engines.Build123d"
    end
  end

  describe "mnft_cad_web/config/runtime.exs (prod-only; evaluated from the file)" do
    setup do
      src = File.read!(Path.join(@project_root, "mnft_cad_web/config/runtime.exs"))

      [expr] =
        Regex.run(~r/case System\.get_env\("MNFT_ENGINE".*?\n\s*end/s, src) ||
                    flunk("no MNFT_ENGINE case expression in runtime.exs")

      prior = System.get_env("MNFT_ENGINE")

      on_exit(fn ->
        if prior, do: System.put_env("MNFT_ENGINE", prior), else: System.delete_env("MNFT_ENGINE")
      end)

      {:ok, expr: expr}
    end

    defp eval_engine(expr, value) do
      if value, do: System.put_env("MNFT_ENGINE", value), else: System.delete_env("MNFT_ENGINE")
      {engine, _} = Code.eval_string(expr)
      engine
    end

    test "smlibpy / openscad / build123d / unset / unknown", %{expr: expr} do
      assert eval_engine(expr, "smlibpy") == Mnft.Cad.Engines.Smlibpy
      assert eval_engine(expr, "openscad") == Mnft.Cad.Engines.OpenScad
      assert eval_engine(expr, "build123d") == Mnft.Cad.Engines.Build123d
      assert eval_engine(expr, nil) == Mnft.Cad.Engines.Build123d
      assert eval_engine(expr, "nonsense") == Mnft.Cad.Engines.Build123d
    end
  end
end

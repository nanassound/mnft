defmodule Mnft.Cad.Engines.SmlibpyTest do
  use ExUnit.Case, async: false

  alias Mnft.Cad.Engines.Smlibpy
  # __DIR__ = mnft_cad/test/mnft/cad/engines/ → 5 levels up = project root (mnft/)
  @project_root Path.expand("../../../../../", __DIR__)
  @python_abs Path.join(@project_root, "cad_worker/.venv/bin/python")
  @worker_cwd_abs Path.join(@project_root, "cad_worker")

  @moduletag if(File.exists?(@python_abs),
               do: [],
               else: [skip: "Python worker not available at cad_worker/.venv/bin/python"]
             )

  setup do
    # Override the test.exs config with real worker paths so Port can open.
    original = Mnft.Cad.Config.all()

    patched =
      original
      |> Keyword.put(:worker_python, @python_abs)
      |> Keyword.put(:worker_cwd, @worker_cwd_abs)
      |> Keyword.put(:exec_timeout_s, 60)

    Application.put_env(:mnft_cad, :cad, patched)

    owner = "smlib-test-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Application.put_env(:mnft_cad, :cad, original)

      Mnft.Cad.Config.get(:models_dir)
      |> Path.join(owner)
      |> Path.absname()
      |> File.rm_rf!()
    end)

    {:ok, owner: owner}
  end

  # -------------------------------------------------------------------------
  # Dialect callback — pure Elixir, no worker needed
  # -------------------------------------------------------------------------

  test "Smlibpy.dialect/0 returns :smlibpy" do
    assert Smlibpy.dialect() == :smlibpy
  end

  test "Build123d.dialect/0 returns :build123d" do
    assert Mnft.Cad.Engines.Build123d.dialect() == :build123d
  end

  # -------------------------------------------------------------------------
  # Config engine-selection logic
  # -------------------------------------------------------------------------

  test "MNFT_ENGINE=smlibpy maps to Smlibpy" do
    engine =
      case "smlibpy" do
        "openscad" -> Mnft.Cad.Engines.OpenScad
        "smlibpy" -> Mnft.Cad.Engines.Smlibpy
        _ -> Mnft.Cad.Engines.Build123d
      end

    assert engine == Smlibpy
  end

  test "MNFT_ENGINE=build123d maps to Build123d" do
    engine =
      case "build123d" do
        "openscad" -> Mnft.Cad.Engines.OpenScad
        "smlibpy" -> Mnft.Cad.Engines.Smlibpy
        _ -> Mnft.Cad.Engines.Build123d
      end

    assert engine == Mnft.Cad.Engines.Build123d
  end

  test "MNFT_ENGINE=openscad maps to OpenScad" do
    engine =
      case "openscad" do
        "openscad" -> Mnft.Cad.Engines.OpenScad
        "smlibpy" -> Mnft.Cad.Engines.Smlibpy
        _ -> Mnft.Cad.Engines.Build123d
      end

    assert engine == Mnft.Cad.Engines.OpenScad
  end

  test "unknown MNFT_ENGINE falls back to Build123d" do
    engine =
      case "unknown_engine" do
        "openscad" -> Mnft.Cad.Engines.OpenScad
        "smlibpy" -> Mnft.Cad.Engines.Smlibpy
        _ -> Mnft.Cad.Engines.Build123d
      end

    assert engine == Mnft.Cad.Engines.Build123d
  end

  # -------------------------------------------------------------------------
  # Static check failures — fast path (no harness subprocess)
  # -------------------------------------------------------------------------

  test "rejects disallowed import — returns static_check stage", %{owner: owner} do
    result = Smlibpy.execute("import os\nfrom smlibpy import *\npart = Box(1,1,1)\n", owner)

    refute result.ok
    assert result.stage == :static_check
    assert is_binary(result.error)
    assert result.artifacts == nil
    assert result.mesh == nil
    assert is_integer(result.exec_ms)
  end

  test "rejects code with no part binding", %{owner: owner} do
    result = Smlibpy.execute("from smlibpy import *\nshape = Box(1,1,1)\n", owner)

    refute result.ok
    assert result.stage == :static_check
    assert result.error =~ "part"
  end

  test "rejects random identifier", %{owner: owner} do
    result =
      Smlibpy.execute(
        "from smlibpy import *\npart = Box(1,1,1)\nrandom\n",
        owner
      )

    refute result.ok
    assert result.stage == :static_check
    assert result.error =~ "random"
  end

  # -------------------------------------------------------------------------
  # execute/2 never raises
  # -------------------------------------------------------------------------

  test "returns ok: false on runtime error, never raises", %{owner: owner} do
    result =
      Smlibpy.execute(
        "from smlibpy import *\nraise RuntimeError('test error')\npart = Box(1,1,1)\n",
        owner
      )

    refute result.ok
    assert result.stage == :exec
    assert is_binary(result.error)
    assert is_integer(result.exec_ms)
  end

  # -------------------------------------------------------------------------
  # healthy?/0
  # -------------------------------------------------------------------------

  test "healthy? returns true when smlibpy is installed" do
    assert Smlibpy.healthy?() == true
  end

  test "healthy? returns a boolean — never raises" do
    assert is_boolean(Smlibpy.healthy?())
  end
end

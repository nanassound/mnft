defmodule Mnft.Cad.Engines.PythonWorkerTest do
  @moduledoc """
  PythonWorker normalisation paths: ok-with-files, ok-but-no-files, exit-before-reply,
  timeout, and healthy?/1 variants.

  Mock workers are tiny Python scripts in a tmp dir; config is temporarily
  overridden so async: false is required.
  """
  use ExUnit.Case, async: false

  alias Mnft.Cad.Engines.PythonWorker
  # __DIR__ = mnft_cad/test/mnft/cad/engines/ → 5 levels up = project root (mnft/)
  @project_root Path.expand("../../../../../", __DIR__)
  @python_abs Path.join(@project_root, "cad_worker/.venv/bin/python")

  @moduletag if(File.exists?(@python_abs),
               do: [],
               else: [skip: "Python worker not available at cad_worker/.venv/bin/python"]
             )

  # -------------------------------------------------------------------------
  # Mock worker helpers
  # -------------------------------------------------------------------------

  defp mock_worker_dir(indented_body) do
    dir =
      System.tmp_dir!()
      |> Path.join("mock_worker_#{System.unique_integer([:positive])}")

    pkg = Path.join(dir, "cad_worker")
    File.mkdir_p!(pkg)
    File.write!(Path.join(pkg, "__init__.py"), "")

    cli_py = """
    import sys, json, os

    def main():
    #{indented_body}

    if __name__ == "__main__":
        sys.exit(main() or 0)
    """

    File.write!(Path.join(pkg, "cli.py"), cli_py)
    dir
  end

  defp with_mock_cfg(mock_cwd, timeout_s \\ 2, fun) do
    original = Mnft.Cad.Config.all()

    patched =
      original
      |> Keyword.put(:worker_cwd, mock_cwd)
      |> Keyword.put(:worker_python, @python_abs)
      |> Keyword.put(:exec_timeout_s, timeout_s)

    Application.put_env(:mnft_cad, :cad, patched)

    try do
      fun.()
    after
      Application.put_env(:mnft_cad, :cad, original)
    end
  end

  defp fresh_owner, do: "pw-test-#{System.unique_integer([:positive])}"

  defp cleanup_owner(owner) do
    models_dir = Mnft.Cad.Config.get(:models_dir) || System.tmp_dir!()
    models_dir |> Path.join(owner) |> Path.absname() |> File.rm_rf!()
  end

  # -------------------------------------------------------------------------
  # Normalisation: exit before reply → error: "worker process exited..."
  # -------------------------------------------------------------------------

  test "exit before reply → ok: false / stage: exec" do
    body = """
        import sys
        sys.exit(1)
    """

    dir = mock_worker_dir(body)
    owner = fresh_owner()
    on_exit(fn -> File.rm_rf!(dir); cleanup_owner(owner) end)

    result =
      with_mock_cfg(dir, fn ->
        PythonWorker.execute("smlibpy", "from smlibpy import *\npart = Box(1,1,1)\n", owner)
      end)

    refute result.ok
    assert result.stage == :exec
    assert is_binary(result.error)
    assert result.artifacts == nil
  end

  # -------------------------------------------------------------------------
  # Normalisation: ok reported but export files missing on disk
  # -------------------------------------------------------------------------

  test "ok reported but model files absent → ok: false / 'exports missing'" do
    body = """
        import sys, json
        reply = {
            "ok": True, "stage": "exec", "error": None,
            "artifacts": {"model_id": "abcdef01",
                          "stl": "model.stl", "step": "model.step", "glb": None},
            "mesh": {"triangles": 4, "bbox_mm": [1, 1, 1], "volume_mm3": 1.0},
            "exec_ms": 10,
        }
        sys.stdout.write(json.dumps(reply) + "\\n")
        sys.stdout.flush()
    """

    dir = mock_worker_dir(body)
    owner = fresh_owner()
    on_exit(fn -> File.rm_rf!(dir); cleanup_owner(owner) end)

    result =
      with_mock_cfg(dir, fn ->
        PythonWorker.execute("smlibpy", "from smlibpy import *\npart = Box(1,1,1)\n", owner)
      end)

    refute result.ok
    assert result.stage == :exec
    assert result.error =~ "exports" or result.error =~ "missing"
    assert result.artifacts == nil
    assert result.mesh == nil
  end

  # -------------------------------------------------------------------------
  # Normalisation: timeout
  # -------------------------------------------------------------------------

  @tag timeout: 15_000
  test "worker timeout → ok: false / stage: exec" do
    body = """
        import time
        time.sleep(60)
    """

    dir = mock_worker_dir(body)
    owner = fresh_owner()
    on_exit(fn -> File.rm_rf!(dir); cleanup_owner(owner) end)

    # exec_timeout_s=1 → deadline (1+5)*1000 = 6000 ms
    result =
      with_mock_cfg(dir, 1, fn ->
        PythonWorker.execute("smlibpy", "from smlibpy import *\npart = Box(1,1,1)\n", owner)
      end)

    refute result.ok
    assert result.stage == :exec
    assert is_binary(result.error)
  end

  # -------------------------------------------------------------------------
  # healthy?/1 — mock variants
  # -------------------------------------------------------------------------

  test "healthy?/1 returns false when worker exits without replying" do
    body = """
        import sys
        sys.exit(1)
    """

    dir = mock_worker_dir(body)
    on_exit(fn -> File.rm_rf!(dir) end)

    result =
      with_mock_cfg(dir, fn ->
        PythonWorker.healthy?("smlibpy")
      end)

    assert result == false
  end

  test "healthy?/1 returns true when worker replies ok: true" do
    body = """
        import sys, json
        sys.stdout.write(json.dumps({"ok": True, "smlibpy": "0.2.3", "python": "3.12"}) + "\\n")
        sys.stdout.flush()
    """

    dir = mock_worker_dir(body)
    on_exit(fn -> File.rm_rf!(dir) end)

    result =
      with_mock_cfg(dir, fn ->
        PythonWorker.healthy?("smlibpy")
      end)

    assert result == true
  end

  # -------------------------------------------------------------------------
  # healthy?/1 must be about THIS dialect's package, not just "worker answered"
  # -------------------------------------------------------------------------

  test "health_key/1 maps each dialect to its own reply key; unknown has none" do
    assert PythonWorker.health_key("build123d") == "build123d"
    assert PythonWorker.health_key("smlibpy") == "smlibpy"
    assert PythonWorker.health_key("openscad") == nil
  end

  describe "health_reply_ok?/2" do
    test "true only when ok and the dialect's own key is non-null" do
      line = ~s({"ok": true, "build123d": "0.13.0", "smlibpy": "0.2.3", "python": "3.12"})
      assert PythonWorker.health_reply_ok?(line, "smlibpy")
      assert PythonWorker.health_reply_ok?(line, "build123d")
    end

    test "missing package (null) is false for that dialect even though ok: true" do
      line = ~s({"ok": true, "build123d": "0.13.0", "smlibpy": null, "python": "3.12"})
      refute PythonWorker.health_reply_ok?(line, "smlibpy")
      assert PythonWorker.health_reply_ok?(line, "build123d")

      line = ~s({"ok": true, "build123d": null, "smlibpy": "0.2.3"})
      refute PythonWorker.health_reply_ok?(line, "build123d")
      assert PythonWorker.health_reply_ok?(line, "smlibpy")
    end

    test "absent key, ok: false, unknown dialect and garbage are all false" do
      refute PythonWorker.health_reply_ok?(~s({"ok": true, "python": "3.12"}), "smlibpy")
      refute PythonWorker.health_reply_ok?(~s({"ok": false, "smlibpy": "0.2.3"}), "smlibpy")
      refute PythonWorker.health_reply_ok?(~s({"ok": true, "openscad": "1"}), "openscad")
      refute PythonWorker.health_reply_ok?("not json", "smlibpy")
    end
  end

  test "healthy?/1 returns false when the worker replies ok but the dialect's package is null" do
    body = """
        import sys, json
        sys.stdout.write(json.dumps({"ok": True, "build123d": "0.13.0", "smlibpy": None}) + "\\n")
        sys.stdout.flush()
    """

    dir = mock_worker_dir(body)
    on_exit(fn -> File.rm_rf!(dir) end)

    assert with_mock_cfg(dir, fn -> PythonWorker.healthy?("smlibpy") end) == false
    assert with_mock_cfg(dir, fn -> PythonWorker.healthy?("build123d") end) == true
  end

  test "healthy?/1 returns false (never raises) when worker_python is nil" do
    original = Mnft.Cad.Config.all()
    # Deliberately blank out worker_python
    Application.put_env(:mnft_cad, :cad, Keyword.put(original, :worker_python, nil))

    on_exit(fn -> Application.put_env(:mnft_cad, :cad, original) end)

    # Must not raise — returns false
    assert PythonWorker.healthy?("smlibpy") == false
  end
end

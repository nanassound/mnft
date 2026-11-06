defmodule MnftOcex.CrossKernelTest do
  @moduledoc """
  The Phase 1 gate: the same construction through the native OCEx engine and
  the build123d Python worker must produce agreeing geometry. This is the
  cross-kernel agreement harness that caught its first discrepancy on day
  zero (both kernels silently no-op cuts that miss the part).
  """

  use ExUnit.Case, async: false

  @tag :cross_kernel
  @tag timeout: 180_000
  test "ocex engine and build123d engine agree on the 25-bore plate" do
    golden = MnftOcex.TestPrograms.bore_plate_volume()

    ocex_run = MnftOcex.Engine.execute(MnftOcex.TestPrograms.bore_plate_json(), "cross-kernel")
    assert ocex_run.ok, "ocex engine failed: #{ocex_run.error}"

    py_run =
      Mnft.Cad.Engines.Build123d.execute(MnftOcex.TestPrograms.bore_plate_python(), "cross-kernel")

    assert py_run.ok, "build123d engine failed: #{py_run.error}"

    ov = mesh_volume(ocex_run.mesh)
    bv = mesh_volume(py_run.mesh)

    # Both engines measure tessellated meshes; kernels agree exactly, meshes
    # differ only by tessellation. 0.1% is far above mesh noise, far below any
    # real construction divergence.
    assert_in_delta ov, bv, max(ov, bv) * 1.0e-3

    # And both agree with the analytic value.
    assert_in_delta ov, golden, golden * 2.0e-3
    assert_in_delta bv, golden, golden * 2.0e-3

    # Bounding boxes: the blank dominates; the bore grid must not change it.
    [ox, oy, oz] = mesh_bbox(ocex_run.mesh)
    [bx, by, bz] = mesh_bbox(py_run.mesh)
    assert_in_delta ox, bx, 0.1
    assert_in_delta oy, by, 0.1
    assert_in_delta oz, bz, 0.1
  end

  # PythonWorker passes the worker's JSON mesh through with string keys; the
  # core's Stl.parse returns atom keys. Read either.
  defp mesh_volume(mesh), do: mesh[:volume_mm3] || mesh["volume_mm3"]

  defp mesh_bbox(mesh), do: mesh[:bbox_mm] || mesh["bbox_mm"]
end

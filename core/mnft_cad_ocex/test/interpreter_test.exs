defmodule MnftOcex.InterpreterTest do
  use ExUnit.Case, async: true

  alias MnftOcex.Interpreter

  defp volume(ops) do
    {:ok, shape} = Interpreter.run(ops)
    {:ok, v} = OCEx.volume(shape)
    v
  end

  test "a box has its analytic volume" do
    assert_in_delta volume([%{"op" => "box", "size" => [60, 40, 5]}]), 60 * 40 * 5, 1.0e-6
  end

  test "a hex prism matches its analytic volume" do
    # regular hexagon area = (3 * sqrt(3) / 2) * r^2 with r the circumradius
    r = 10.0
    area = 3 * :math.sqrt(3) / 2 * r * r

    ops = [%{"op" => "prism", "n" => 6, "r" => r, "h" => 8}]
    assert_in_delta volume(ops), area * 8, 1.0e-6
  end

  test "a hex prism bore removes its analytic area from a plate" do
    r = 5.0
    hex_area = 3 * :math.sqrt(3) / 2 * r * r

    ops = [
      %{"op" => "box", "size" => [60, 40, 5]},
      %{"op" => "prism", "n" => 6, "r" => r, "h" => 20, "at" => [30, 20, -5]},
      %{"op" => "cut"}
    ]

    assert_in_delta volume(ops), 60 * 40 * 5 - hex_area * 5, 1.0e-4
  end

  test "the 25-bore plate matches its analytic volume" do
    ops = MnftOcex.TestPrograms.bore_plate_ops()
    assert_in_delta volume(ops), MnftOcex.TestPrograms.bore_plate_volume(), 1.0e-4
  end

  test "translate moves shapes: two disjoint boxes fuse to the summed volume" do
    ops = [
      %{"op" => "box", "size" => [10, 10, 10]},
      %{"op" => "box", "size" => [10, 10, 10], "at" => [20, 0, 0]},
      %{"op" => "union"}
    ]

    assert_in_delta volume(ops), 2_000, 1.0e-6
  end

  test "intersect keeps only the shared region" do
    ops = [
      %{"op" => "box", "size" => [60, 40, 5]},
      %{"op" => "box", "size" => [30, 20, 5]},
      %{"op" => "intersect"}
    ]

    assert_in_delta volume(ops), 30 * 20 * 5, 1.0e-6
  end

  test "cut subtracts the tool from the blank" do
    ops = [
      %{"op" => "box", "size" => [60, 40, 5]},
      %{"op" => "cylinder", "r" => 4, "h" => 20, "at" => [30, 20, -5]},
      %{"op" => "cut"}
    ]

    expected = 60 * 40 * 5 - :math.pi() * 16 * 5
    assert_in_delta volume(ops), expected, 1.0e-4
  end

  test "fillet_all removes material from every edge" do
    ops = [
      %{"op" => "box", "size" => [60, 40, 5]},
      %{"op" => "fillet_all", "r" => 1}
    ]

    # Golden from the OCEx kernel, measured 5 Nov 2026 (smoke run).
    assert_in_delta volume(ops), 11_911.206462910166, 1.0e-3
  end

  # --- sketch layer: polygon / extrude / rotate --------------------------------

  @hex_prism_area 0.5 * 6 * 400 * :math.sin(:math.pi() / 3)

  test "polygon + extrude builds a hexagonal prism with analytic volume" do
    ops = [
      %{"op" => "polygon", "n" => 6, "r" => 20},
      %{"op" => "extrude", "h" => 10}
    ]

    assert_in_delta volume(ops), @hex_prism_area * 10, 1.0e-3
  end

  test "prism is sugar for polygon + extrude (identical volume)" do
    sugar =
      volume([
        %{"op" => "polygon", "n" => 6, "r" => 20},
        %{"op" => "extrude", "h" => 10}
      ])

    explicit = volume([%{"op" => "prism", "n" => 6, "r" => 20, "h" => 10}])
    assert_in_delta sugar, explicit, 1.0e-6
  end

  test "extrude honours a custom direction (downward is valid, in-plane is rejected)" do
    ops = [
      %{"op" => "polygon", "n" => 6, "r" => 20},
      %{"op" => "extrude", "h" => 10, "dir" => [0, 0, -1]}
    ]

    assert_in_delta volume(ops), @hex_prism_area * 10, 1.0e-3
  end

  test "in-plane extrusion is a tagged degenerate error" do
    ops = [
      %{"op" => "polygon", "n" => 6, "r" => 20},
      %{"op" => "extrude", "h" => 10, "dir" => [1, 0, 0]}
    ]

    assert {:error, msg} = Interpreter.run(ops)
    assert msg =~ "op 2" and msg =~ "planar face"
  end

  test "polygon honours at placement" do
    ops = [
      %{"op" => "polygon", "n" => 6, "r" => 20, "at" => [50, 0, 0]},
      %{"op" => "extrude", "h" => 10}
    ]

    assert_in_delta volume(ops), @hex_prism_area * 10, 1.0e-3
  end

  test "rotate preserves volume" do
    base = [
      %{"op" => "polygon", "n" => 6, "r" => 20},
      %{"op" => "extrude", "h" => 10}
    ]

    assert_in_delta volume(base ++ [%{"op" => "rotate", "axis" => [0, 0, 1], "degrees" => 45}]),
                    @hex_prism_area * 10,
                    1.0e-3
  end

  test "extrude on a solid is a tagged error" do
    ops = [%{"op" => "box", "size" => [10, 10, 10]}, %{"op" => "extrude", "h" => 5}]
    assert {:error, msg} = Interpreter.run(ops)
    assert msg =~ "op 2" and msg =~ "planar face"
  end

  test "rotate on an empty stack is a tagged error" do
    assert {:error, msg} =
             Interpreter.run([%{"op" => "rotate", "axis" => [0, 0, 1], "degrees" => 90}])

    assert msg =~ "op 1" and msg =~ "stack is empty"
  end

  test "cut with only a tool on the stack is a tagged error" do
    assert {:error, msg} = Interpreter.run([%{"op" => "box", "size" => [1, 2, 3]}, %{"op" => "cut"}])
    assert msg =~ "op 2" and msg =~ "blank and a tool"
  end

  test "two leftover shapes are a tagged error" do
    ops = [%{"op" => "box", "size" => [1, 2, 3]}, %{"op" => "box", "size" => [4, 5, 6]}]
    assert {:error, msg} = Interpreter.run(ops)
    assert msg =~ "exactly one shape" and msg =~ "got 2"
  end

  test "an empty program is a tagged error" do
    assert {:error, msg} = Interpreter.run([])
    assert msg =~ "exactly one shape" and msg =~ "got 0"
  end

  test "sphere places and sizes correctly" do
    ops = [%{"op" => "sphere", "r" => 10}]
    assert_in_delta volume(ops), 4 / 3 * :math.pi() * 1_000, 1.0e-4
  end

  # --- profiles: polyline -------------------------------------------------------

  @l_profile [[0, 0, 0], [40, 0, 0], [40, 10, 0], [10, 10, 0], [10, 40, 0], [0, 40, 0]]

  test "a closed polyline L-profile extrudes to its analytic volume" do
    ops = [%{"op" => "polyline", "pts" => @l_profile}, %{"op" => "extrude", "h" => 8}]

    # L area = 40*10 bar + 10*40 bar − 10*10 corner overlap = 700
    assert_in_delta volume(ops), 700 * 8, 1.0e-3
  end

  test "an open polyline pushes a wire, which a boolean rejects as a tool" do
    ops = [
      %{"op" => "polyline", "pts" => [[0, 0, 0], [20, 0, 0], [20, 10, 0]], "close" => false}
    ]

    assert {:ok, _wire} = Interpreter.run(ops)

    bad = [
      %{"op" => "box", "size" => [10, 10, 10]},
      %{"op" => "polyline", "pts" => [[0, 0, 0], [20, 0, 0]], "close" => false},
      %{"op" => "cut"}
    ]

    assert {:error, msg} = Interpreter.run(bad)
    assert msg =~ "op 3" and msg =~ "cut failed"
  end

  # --- patterns ----------------------------------------------------------------

  test "pattern_linear fuses disjoint copies into a compound with summed volume" do
    ops = [
      %{"op" => "box", "size" => [20, 10, 10]},
      %{"op" => "pattern_linear", "count" => 3, "delta" => [30, 0, 0]}
    ]

    assert_in_delta volume(ops), 3 * 2_000, 1.0e-3
  end

  test "pattern_circular lays out six cylinders on a bolt circle" do
    ops = [
      %{"op" => "cylinder", "r" => 2, "h" => 10, "at" => [40, 40, -5]},
      %{"op" => "pattern_circular", "count" => 6, "at" => [0, 40, -5]}
    ]

    assert_in_delta volume(ops), 6 * :math.pi() * 4 * 10, 1.0e-2
  end

  test "a patterned bore tool cuts all instances at once (compound-aware cut)" do
    ops = [
      %{"op" => "box", "size" => [100, 100, 10]},
      %{"op" => "cylinder", "r" => 3, "h" => 20, "at" => [50, 20, -5]},
      %{"op" => "pattern_circular", "count" => 4, "at" => [50, 50, 0]},
      %{"op" => "cut"}
    ]

    assert_in_delta volume(ops), 100_000 - 4 * :math.pi() * 9 * 10, 1.0e-1
  end

  test "pattern_linear on an empty stack is a tagged error" do
    assert {:error, msg} =
             Interpreter.run([%{"op" => "pattern_linear", "count" => 3, "delta" => [10, 0, 0]}])

    assert msg =~ "op 1" and msg =~ "pattern_linear" and msg =~ "stack is empty"
  end

  test "pattern_circular on an empty stack is a tagged error" do
    assert {:error, msg} = Interpreter.run([%{"op" => "pattern_circular", "count" => 4}])
    assert msg =~ "op 1" and msg =~ "pattern_circular" and msg =~ "stack is empty"
  end

  # --- sweeps: revolve / loft, named solids: cone / torus ----------------------

  # Rectangle in the XZ plane (y=0), which contains the z axis; r 20..30, h 5.
  @revolve_profile [[20, 0, 0], [30, 0, 0], [30, 0, 5], [20, 0, 5]]

  test "revolve sweeps an XZ rectangle about z into an analytic ring" do
    ops = [
      %{"op" => "polyline", "pts" => @revolve_profile},
      %{"op" => "revolve", "axis" => [0, 0, 1]}
    ]

    assert_in_delta volume(ops), :math.pi() * (900 - 400) * 5, 1.0e-2
  end

  test "revolve of 180 degrees gives half the ring" do
    ops = [
      %{"op" => "polyline", "pts" => @revolve_profile},
      %{"op" => "revolve", "axis" => [0, 0, 1], "degrees" => 180}
    ]

    assert_in_delta volume(ops), :math.pi() * 500 * 5 / 2, 1.0e-2
  end

  test "revolve on a solid is a tagged error" do
    ops = [%{"op" => "box", "size" => [10, 10, 10]}, %{"op" => "revolve", "axis" => [0, 0, 1]}]
    assert {:error, msg} = Interpreter.run(ops)
    assert msg =~ "op 2" and msg =~ "planar face"
  end

  test "loft of congruent sections equals the prism volume" do
    ops = [
      %{"op" => "polygon", "n" => 6, "r" => 20},
      %{"op" => "polygon", "n" => 6, "r" => 20, "at" => [0, 0, 10]},
      %{"op" => "loft", "sections" => 2}
    ]

    assert_in_delta volume(ops), @hex_prism_area * 10, 1.0e-3
  end

  test "loft with fewer shapes on the stack is a tagged error" do
    ops = [%{"op" => "polygon", "n" => 6, "r" => 10}, %{"op" => "loft", "sections" => 3}]
    assert {:error, msg} = Interpreter.run(ops)
    assert msg =~ "op 2" and msg =~ "needs 3"
  end

  test "cone frustum and apex cone have analytic volumes" do
    assert_in_delta volume([%{"op" => "cone", "r1" => 10, "r2" => 5, "h" => 20}]),
                    :math.pi() * 20 / 3 * (100 + 50 + 25),
                    1.0e-2

    assert_in_delta volume([%{"op" => "cone", "r1" => 10, "r2" => 0, "h" => 20}]),
                    :math.pi() * 100 * 20 / 3,
                    1.0e-2
  end

  test "torus has its analytic volume and honours at" do
    assert_in_delta volume([%{"op" => "torus", "R" => 20, "r" => 4}]),
                    2 * :math.pi() * :math.pi() * 20 * 16,
                    1.0e-2

    assert_in_delta volume([%{"op" => "torus", "R" => 20, "r" => 4, "at" => [50, 0, 0]}]),
                    2 * :math.pi() * :math.pi() * 20 * 16,
                    1.0e-2
  end

  # --- transforms: mirror / scale ----------------------------------------------

  test "mirror of a disjoint half doubles the volume" do
    ops = [
      %{"op" => "box", "size" => [10, 10, 10], "at" => [15, 0, 0]},
      %{"op" => "mirror", "normal" => [1, 0, 0]}
    ]

    assert_in_delta volume(ops), 2_000, 1.0e-3
  end

  test "mirror about a cutting plane through the part completes the symmetric half" do
    half = [
      %{"op" => "box", "size" => [10, 40, 5], "at" => [10, 0, 0]},
      %{"op" => "mirror", "normal" => [1, 0, 0], "at" => [20, 0, 0]}
    ]

    assert_in_delta volume(half), 2 * 10 * 40 * 5, 1.0e-3
  end

  test "scale multiplies volume and grows the bbox about the origin" do
    ops = [%{"op" => "box", "size" => [10, 10, 10]}, %{"op" => "scale", "factor" => 2}]

    assert {:ok, shape} = Interpreter.run(ops)
    assert_in_delta volume(ops), 8_000, 1.0e-3

    assert {:ok, {{x0, y0, z0}, {x1, y1, z1}}} = OCEx.bounds(shape)
    assert_in_delta x1, 20.0, 1.0e-6
    assert_in_delta y1, 20.0, 1.0e-6
    assert_in_delta z1, 20.0, 1.0e-6
    assert_in_delta x0, 0.0, 1.0e-6
  end

  test "mirror and scale on an empty stack are tagged errors" do
    assert {:error, msg} = Interpreter.run([%{"op" => "mirror", "normal" => [0, 0, 1]}])
    assert msg =~ "op 1" and msg =~ "mirror" and msg =~ "stack is empty"

    assert {:error, msg} = Interpreter.run([%{"op" => "scale", "factor" => 2}])
    assert msg =~ "op 1" and msg =~ "scale" and msg =~ "stack is empty"
  end
end

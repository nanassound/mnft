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
end

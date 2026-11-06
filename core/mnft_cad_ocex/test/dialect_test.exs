defmodule MnftOcex.DialectTest do
  use ExUnit.Case, async: true

  alias MnftOcex.Dialect

  defp err(json), do: Dialect.validate(json)

  test "accepts a well-formed program" do
    json =
      Jason.encode!(%{
        "ops" => [
          %{"op" => "box", "size" => [60, 40, 5]},
          %{"op" => "cylinder", "r" => 4, "h" => 20, "at" => [30, 20, -5]},
          %{"op" => "cut"}
        ]
      })

    assert {:ok, ops} = Dialect.validate(json)
    assert length(ops) == 3
  end

  test "rejects non-JSON input" do
    assert {:error, msg} = err("this is not json")
    assert msg =~ "invalid JSON"
  end

  test "accepts a prism with sides, radius and height" do
    json =
      Jason.encode!(%{
        "ops" => [%{"op" => "prism", "n" => 6, "r" => 10, "h" => 5, "at" => [30, 20, 0]}]
      })

    assert {:ok, [_op]} = Dialect.validate(json)
  end

  test "rejects a prism with fewer than 3 sides" do
    json = Jason.encode!(%{"ops" => [%{"op" => "prism", "n" => 2, "r" => 10, "h" => 5}]})
    assert {:error, msg} = err(json)
    assert msg =~ "\"n\" must be between 3 and 64"
  end

  test "rejects a prism with a non-integer n" do
    json = Jason.encode!(%{"ops" => [%{"op" => "prism", "n" => 6.5, "r" => 10, "h" => 5}]})
    assert {:error, msg} = err(json)
    assert msg =~ "\"n\" must be an integer"
  end

  test "rejects a prism without n" do
    json = Jason.encode!(%{"ops" => [%{"op" => "prism", "r" => 10, "h" => 5}]})
    assert {:error, msg} = err(json)
    assert msg =~ "missing \"n\""
  end

  test "rejects a program without an ops array" do
    assert {:error, msg} = err(~s({"model": "plate"}))
    assert msg =~ "\"ops\""
  end

  test "rejects an empty ops array" do
    assert {:error, msg} = err(~s({"ops": []}))
    assert msg =~ "empty"
  end

  test "rejects an ops value that is not an array" do
    assert {:error, msg} = err(~s({"ops": "box"}))
    assert msg =~ "must be a non-empty array"
  end

  test "rejects an unknown op" do
    assert {:error, msg} = err(~s({"ops": [{"op": "torus", "r": 5}]}))
    assert msg =~ "unknown op"
    assert msg =~ "torus"
  end

  test "rejects an op without an op key" do
    assert {:error, msg} = err(~s({"ops": [{"size": [1, 2, 3]}]}))
    assert msg =~ "every op must be an object"
  end

  test "rejects box without size" do
    assert {:error, msg} = err(~s({"ops": [{"op": "box"}]}))
    assert msg =~ "missing \"size\""
  end

  test "rejects box with a two-entry size" do
    assert {:error, msg} = err(~s({"ops": [{"op": "box", "size": [1, 2]}]}))
    assert msg =~ "[x, y, z]"
  end

  test "rejects box with a non-numeric size" do
    assert {:error, msg} = err(~s({"ops": [{"op": "box", "size": [1, "2", 3]}]}))
    assert msg =~ "[x, y, z]"
  end

  test "rejects zero and negative dimensions" do
    assert {:error, msg} = err(~s({"ops": [{"op": "box", "size": [0, 40, 5]}]}))
    assert msg =~ "positive"

    assert {:error, msg} = err(~s({"ops": [{"op": "cylinder", "r": -3, "h": 20}]}))
    assert msg =~ "positive"
  end

  test "rejects cylinder missing h" do
    assert {:error, msg} = err(~s({"ops": [{"op": "cylinder", "r": 3}]}))
    assert msg =~ "missing \"h\""
  end

  test "rejects translate with a two-entry delta" do
    assert {:error, msg} = err(~s({"ops": [{"op": "box", "size": [1, 2, 3]}, {"op": "translate", "delta": [1, 2]}]}))
    assert msg =~ "delta"
  end

  test "rejects a boolean op that takes at" do
    assert {:error, msg} = err(~s({"ops": [{"op": "cut", "at": [1, 2, 3]}]}))
    assert msg =~ "takes no \"at\""
  end

  test "rejects fillet_all with a non-positive radius" do
    assert {:error, msg} = err(~s({"ops": [{"op": "box", "size": [1, 2, 3]}, {"op": "fillet_all", "r": 0}]}))
    assert msg =~ "positive"
  end

  test "rejects more than 200 ops" do
    box = ~s({"op": "box", "size": [1, 1, 1]})
    ops = List.duplicate(box, 201) |> Enum.join(", ")
    assert {:error, msg} = err(~s({"ops": [#{ops}]}))
    assert msg =~ "more than 200"
  end

  test "rejects oversized programs by bytes" do
    assert {:error, msg} = err(String.duplicate("a", 21_000))
    assert msg =~ "exceeds"
  end

  # --- sketch layer: polygon / extrude / rotate --------------------------------

  test "polygon validates n as an integer >= 3" do
    assert {:error, msg} = err(~s({"ops": [{"op": "polygon", "n": 2, "r": 20}]}))
    assert msg =~ "integer from 3 to 120"

    assert {:error, msg} = err(~s({"ops": [{"op": "polygon", "n": 2.5, "r": 20}]}))
    assert msg =~ "integer from 3 to 120"

    assert {:error, msg} = err(~s({"ops": [{"op": "polygon", "r": 20}]}))
    assert msg =~ "missing \"n\""
  end

  test "polygon validates r and optional rot" do
    assert {:error, msg} = err(~s({"ops": [{"op": "polygon", "n": 6}]}))
    assert msg =~ "missing \"r\""

    assert {:error, msg} = err(~s({"ops": [{"op": "polygon", "n": 6, "r": 20, "rot": "x"}]}))
    assert msg =~ "\"rot\" must be a finite number"
  end

  test "extrude validates h and a nonzero dir" do
    assert {:error, msg} = err(~s({"ops": [{"op": "extrude"}]}))
    assert msg =~ "missing \"h\""

    assert {:error, msg} =
             err(~s({"ops": [{"op": "extrude", "h": 10, "dir": [0, 0, 0]}]}))

    assert msg =~ "must not be the zero vector"
  end

  test "rotate validates a nonzero axis and finite degrees" do
    assert {:error, msg} = err(~s({"ops": [{"op": "rotate", "axis": [0, 0, 0], "degrees": 90}]}))
    assert msg =~ "must not be the zero vector"

    assert {:error, msg} = err(~s({"ops": [{"op": "rotate", "axis": [0, 0, 1]}]}))
    assert msg =~ "missing \"degrees\""

    assert {:error, msg} =
             err(~s({"ops": [{"op": "rotate", "axis": [0, 0, 1], "degrees": "ninety"}]}))

    assert msg =~ "\"degrees\" must be a finite number"
  end

  # --- profiles: polyline -------------------------------------------------------

  test "accepts a two-point closed polyline" do
    assert {:ok, _} = err(~s({"ops": [{"op": "polyline", "pts": [[0, 0, 0], [10, 0, 0]]}]}))
  end

  test "rejects a polyline with a single point" do
    assert {:error, msg} = err(~s({"ops": [{"op": "polyline", "pts": [[0, 0, 0]]}]}))
    assert msg =~ "at least 2 points"
  end

  test "rejects a polyline with more than 512 points" do
    pts = for n <- 0..512, do: [n, 0, 0]
    assert {:error, msg} = err(Jason.encode!(%{"ops" => [%{"op" => "polyline", "pts" => pts}]}))
    assert msg =~ "at most 512 points"
  end

  test "rejects a polyline with a non-vec3 point" do
    assert {:error, msg} = err(~s({"ops": [{"op": "polyline", "pts": [[0, 0], [10, 0, 0]]}]}))
    assert msg =~ "[x, y, z]"
  end

  test "rejects consecutive duplicate polyline points" do
    assert {:error, msg} =
             err(~s({"ops": [{"op": "polyline", "pts": [[0, 0, 0], [0, 0, 0], [10, 0, 0]]}]}))

    assert msg =~ "consecutive duplicate"
  end

  test "rejects a polyline with a non-boolean close" do
    assert {:error, msg} =
             err(~s({"ops": [{"op": "polyline", "pts": [[0, 0, 0], [10, 0, 0]], "close": "yes"}]}))

    assert msg =~ "must be a boolean"
  end

  test "rejects a polyline with a malformed at" do
    assert {:error, msg} =
             err(~s({"ops": [{"op": "polyline", "pts": [[0, 0, 0], [10, 0, 0]], "at": [0, 0]}]}))

    assert msg =~ "\"at\""
  end
end

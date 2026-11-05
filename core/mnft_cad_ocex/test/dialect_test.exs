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
end

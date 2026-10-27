defmodule PopcornDemoTest do
  use ExUnit.Case
  doctest PopcornDemo

  test "greets the world" do
    assert PopcornDemo.hello() == :world
  end
end

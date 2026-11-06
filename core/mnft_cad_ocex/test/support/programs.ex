defmodule MnftOcex.TestPrograms do
  @moduledoc """
  Shared constructions for the engine tests: the 25-bore plate is the golden
  cross-kernel model (volume verified analytically and against build123d).
  """

  @doc "100x100x10 plate, 5x5 grid of r=3 through-bores. Analytic volume 92931.4165 mm3."
  def bore_plate_ops do
    bores =
      for x <- [10, 30, 50, 70, 90], y <- [10, 30, 50, 70, 90] do
        %{"op" => "cylinder", "r" => 3, "h" => 20, "at" => [x, y, -5]}
      end

    cuts = for _ <- bores, do: %{"op" => "cut"}

    plate = [%{"op" => "box", "size" => [100, 100, 10]}]
    # NB: `++` binds tighter than `|>` — flat_map first, then prepend the plate.
    plate ++ Enum.flat_map(Enum.zip(bores, cuts), &Tuple.to_list/1)
  end

  def bore_plate_json, do: Jason.encode!(%{"ops" => bore_plate_ops()})

  @doc "build123d twin of `bore_plate_ops`, for the cross-kernel agreement test."
  def bore_plate_python do
    ~S"""
    from build123d import *
    part = Box(100, 100, 10, align=(Align.MIN, Align.MIN, Align.MIN))
    for x in (10, 30, 50, 70, 90):
        for y in (10, 30, 50, 70, 90):
            part = part - (Pos(x, y, -5) * Cylinder(3, 20, align=(Align.CENTER, Align.CENTER, Align.MIN)))
    """
  end

  @doc "Analytic volume of the bore plate in mm3."
  def bore_plate_volume, do: 100_000 - 25 * :math.pi() * 9 * 10
end

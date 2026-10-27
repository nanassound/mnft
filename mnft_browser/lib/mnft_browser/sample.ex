defmodule MnftBrowser.Sample do
  @moduledoc """
  The fake-LLM's part: `cad_worker_web`'s sample (a 40 mm hexagonal pen
  holder, 3 mm wall) with the height parameterized. `h` varies per scripted
  turn so each turn produces a strictly different model.
  """

  @spec script(number()) :: String.t()
  def script(h) do
    """
    // 40 mm hexagonal pen holder, 3 mm wall, #{fmt(h)} mm tall
    // (port of cad_worker/examples/sample_part.py to the replicad dialect)

    const acrossFlats = 40.0;
    const wall = 3.0;
    const height = #{fmt(h)};

    // hexagon specified by its across-flats (apothem): convert to circumradius
    const circumRadius = (across) => across / 2 / Math.cos(pi / 6);

    const outer = sketchPolysides(circumRadius(acrossFlats), 6).extrude(height);
    const inner = sketchPolysides(circumRadius(acrossFlats - 2 * wall), 6).extrude(height);
    const part = outer.cut(inner.translate(0, 0, wall));
    """
    |> String.trim_trailing()
  end

  defp fmt(h), do: :erlang.float_to_binary(h * 1.0, decimals: 1)
end

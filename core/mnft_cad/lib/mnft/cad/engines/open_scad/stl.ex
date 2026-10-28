defmodule Mnft.Cad.Engines.OpenScad.Stl do
  @moduledoc """
  Parser for binary STL files: 80-byte header, u32 LE triangle count, then
  per triangle 12 bytes normal + 9 f32 LE vertices + u16 attribute.

  Computes triangle count, bounding box (mm) and signed-tetrahedron volume
  (mm^3, absolute value). ASCII STL is rejected.
  """

  @type mesh :: %{triangles: non_neg_integer(), bbox_mm: [float()], volume_mm3: float()}

  @spec parse(String.t()) :: {:ok, mesh()} | {:error, term()}
  def parse(path) do
    case File.read(path) do
      {:ok, data} -> parse_binary(data)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_binary(data) when byte_size(data) < 84 do
    {:error, if(ascii?(data), do: :ascii_stl, else: :short_file)}
  end

  defp parse_binary(data) do
    if ascii?(data) do
      {:error, :ascii_stl}
    else
      <<_header::binary-size(80), count::little-unsigned-integer-size(32), rest::binary>> = data

      expected = 84 + count * 50

      if byte_size(data) != expected do
        {:error, :short_file}
      else
        {:ok, measure(rest, count, %{triangles: count, min: nil, max: nil, volume: 0.0})}
      end
    end
  end

  defp ascii?(<<>>), do: false

  defp ascii?(data) do
    case data do
      <<"solid", _::binary>> -> true
      _ -> false
    end
  end

  defp measure(_rest, 0, acc) do
    %{
      triangles: acc.triangles,
      bbox_mm: [
        acc.max.x - acc.min.x,
        acc.max.y - acc.min.y,
        acc.max.z - acc.min.z
      ],
      volume_mm3: abs(acc.volume)
    }
  end

  defp measure(
         <<_normal::binary-size(12), verts::binary-size(36), _attr::binary-size(2),
           rest::binary>>,
         n,
         acc
       ) do
    [x1, y1, z1, x2, y2, z2, x3, y3, z3] =
      for <<v::little-float-size(32) <- verts>>, do: v

    acc =
      acc
      |> bound(x1, y1, z1)
      |> bound(x2, y2, z2)
      |> bound(x3, y3, z3)
      |> Map.update!(
        :volume,
        &(&1 +
            (x1 * (y2 * z3 - y3 * z2) - y1 * (x2 * z3 - x3 * z2) +
               z1 * (x2 * y3 - x3 * y2)) / 6)
      )

    measure(rest, n - 1, acc)
  end

  defp bound(%{min: nil} = acc, x, y, z) do
    %{acc | min: %{x: x, y: y, z: z}, max: %{x: x, y: y, z: z}}
  end

  defp bound(acc, x, y, z) do
    %{
      acc
      | min: %{
          x: min(acc.min.x, x),
          y: min(acc.min.y, y),
          z: min(acc.min.z, z)
        },
        max: %{
          x: max(acc.max.x, x),
          y: max(acc.max.y, y),
          z: max(acc.max.z, z)
        }
    }
  end
end

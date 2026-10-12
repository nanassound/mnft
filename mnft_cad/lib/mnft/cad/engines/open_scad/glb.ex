defmodule Mnft.Cad.Engines.OpenScad.Glb do
  @moduledoc """
  Minimal GLB 2.0 writer: reads a binary STL and emits a single-mesh GLB with
  u32 triangle indices and f32 positions (vertices kept per-triangle, indexed
  sequentially — no dedupe). Best-effort preview format only.
  """

  @component_u32 5125
  @component_vec3_f32 5126

  @spec write(String.t(), String.t()) :: :ok | {:error, term()}
  def write(stl_path, glb_path) do
    with {:ok, {n, tris}} <- stl_triangles(stl_path),
         {:ok, json_bin} <- build_json(n, tris) do
      bin = buffers_bin(n, tris)
      File.write(glb_path, container(json_bin, bin))
    end
  end

  defp stl_triangles(path) do
    case File.read(path) do
      {:ok, data} -> parse_tris(data)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_tris(<<_::binary-size(80), n::little-unsigned-integer-size(32), rest::binary>>) do
    tris =
      for <<(<<_::binary-size(12), verts::binary-size(36), _::binary-size(2)>> <- rest)>> do
        for <<v::little-float-size(32) <- verts>> do
          v
        end
      end

    {:ok, {n, tris}}
  end

  defp parse_tris(_other), do: {:error, :bad_stl}

  defp build_json(n, tris) do
    {min, max} = bounds(tris)

    json = %{
      "asset" => %{"version" => "2.0"},
      "scene" => 0,
      "scenes" => [%{"nodes" => [0]}],
      "nodes" => [%{"mesh" => 0}],
      "meshes" => [
        %{"primitives" => [%{"attributes" => %{"POSITION" => 1}, "indices" => 0}]}
      ],
      "accessors" => [
        %{
          "bufferView" => 0,
          "componentType" => @component_u32,
          "count" => n * 3,
          "type" => "SCALAR",
          "min" => [0],
          "max" => [n * 3 - 1]
        },
        %{
          "bufferView" => 1,
          "componentType" => @component_vec3_f32,
          "count" => n * 3,
          "type" => "VEC3",
          "min" => min,
          "max" => max
        }
      ],
      "bufferViews" => [
        %{"buffer" => 0, "byteOffset" => 0, "byteLength" => n * 3 * 4},
        %{"buffer" => 0, "byteOffset" => n * 3 * 4, "byteLength" => n * 3 * 12}
      ],
      "buffers" => [%{"buffer" => 0, "byteLength" => n * 48}]
    }

    Jason.encode(json)
  end

  defp buffers_bin(n, tris) do
    indices = for i <- 0..(n * 3 - 1), do: <<i::little-unsigned-integer-size(32)>>

    positions =
      for verts <- tris, v <- verts do
        <<v::little-float-size(32)>>
      end

    IO.iodata_to_binary([indices, positions])
  end

  defp bounds(tris) do
    flat = List.flatten(tris)
    [xs, ys, zs] = for i <- 0..2, do: flat |> Enum.drop(i) |> Enum.take_every(3)

    {[Enum.min(xs), Enum.min(ys), Enum.min(zs)], [Enum.max(xs), Enum.max(ys), Enum.max(zs)]}
  end

  # --- GLB container framing ---------------------------------------------------

  defp container(json, bin) do
    json_bin = pad(json, 32, ?\s)
    bin_pad = pad(bin, 4, 0)
    json_len = byte_size(json_bin)
    bin_len = byte_size(bin_pad)
    total = 12 + 8 + json_len + 8 + bin_len

    <<
      "glTF",
      2::little-unsigned-integer-size(32),
      total::little-unsigned-integer-size(32),
      json_len::little-unsigned-integer-size(32),
      0x4E4F534A::little-unsigned-integer-size(32),
      json_bin::binary,
      bin_len::little-unsigned-integer-size(32),
      0x004E4942::little-unsigned-integer-size(32),
      bin_pad::binary
    >>
  end

  defp pad(bin, align, byte) do
    case rem(byte_size(bin), align) do
      0 -> bin
      r -> bin <> :binary.copy(<<byte>>, align - r)
    end
  end
end

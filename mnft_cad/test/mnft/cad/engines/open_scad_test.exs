defmodule Mnft.Cad.Engines.OpenScadTest do
  use ExUnit.Case, async: true

  alias Mnft.Cad.Engines.OpenScad
  alias Mnft.Cad.Engines.OpenScad.Glb
  alias Mnft.Cad.Engines.OpenScad.Stl

  @tmp_dir System.tmp_dir!() |> Path.join("openscad_engine_test-#{:rand.uniform(1_000_000)}")

  # --- fixtures ----------------------------------------------------------------

  # Tetrahedron with vertices at origin and on the axes: volume = a*b*c/6 = 1/6.
  defp tetra_stl do
    v = fn x, y, z ->
      <<x::little-float-size(32), y::little-float-size(32), z::little-float-size(32)>>
    end

    o = v.(0.0, 0.0, 0.0)
    a = v.(1.0, 0.0, 0.0)
    b = v.(0.0, 1.0, 0.0)
    c = v.(0.0, 0.0, 1.0)

    tris =
      for {p, q, r} <- [{o, a, b}, {o, b, c}, {o, c, a}, {a, c, b}] do
        <<0.0::little-float-size(32), 0.0::little-float-size(32), 0.0::little-float-size(32),
          p::binary, q::binary, r::binary, 0::little-unsigned-integer-size(16)>>
      end

    count = length(tris)
    body = IO.iodata_to_binary(tris)
    <<String.duplicate("x", 80)::binary, count::little-unsigned-integer-size(32), body::binary>>
  end

  defp write_stl(data, name) do
    dir = Path.join(@tmp_dir, "#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, data)
    path
  end

  # --- STL parse ---------------------------------------------------------------

  test "parses binary STL of a tetrahedron with exact volume" do
    {:ok, mesh} = tetra_stl() |> write_stl("tetra.stl") |> Stl.parse()

    assert mesh.triangles == 4
    assert mesh.bbox_mm == [1.0, 1.0, 1.0]
    assert_in_delta mesh.volume_mm3, 1.0 / 6.0, 1.0e-3
  end

  test "measures two-triangle unit square bbox" do
    v = fn x, y, z ->
      <<x::little-float-size(32), y::little-float-size(32), z::little-float-size(32)>>
    end

    tri = fn p, q, r ->
      <<0.0::little-float-size(32), 0.0::little-float-size(32), 1.0::little-float-size(32),
        p::binary, q::binary, r::binary, 0::little-unsigned-integer-size(16)>>
    end

    data =
      <<String.duplicate("\0", 80)::binary, 2::little-unsigned-integer-size(32),
        IO.iodata_to_binary([
          tri.(v.(0.0, 0.0, 0.0), v.(1.0, 0.0, 0.0), v.(1.0, 1.0, 0.0)),
          tri.(v.(0.0, 0.0, 0.0), v.(1.0, 1.0, 0.0), v.(0.0, 1.0, 0.0))
        ])::binary>>

    {:ok, mesh} = data |> write_stl("square.stl") |> Stl.parse()
    assert mesh.triangles == 2
    assert mesh.bbox_mm == [1.0, 1.0, 0.0]
    assert_in_delta mesh.volume_mm3, 0.0, 1.0e-3
  end

  test "rejects an ascii STL" do
    ascii = String.duplicate("solid ascii stl padded to enough bytes", 4)
    assert {:error, :ascii_stl} == ascii |> write_stl("ascii.stl") |> Stl.parse()
  end

  test "rejects a torn/short binary STL" do
    torn = binary_part(tetra_stl(), 0, 100)
    assert {:error, :short_file} == torn |> write_stl("torn.stl") |> Stl.parse()
    assert {:error, :short_file} == "" |> write_stl("empty.stl") |> Stl.parse()
  end

  test "rejects a missing file" do
    assert {:error, _} = Stl.parse(Path.join(@tmp_dir, "does-not-exist.stl"))
  end

  # --- GLB ---------------------------------------------------------------------

  test "writes a structurally valid GLB from a binary STL" do
    stl_path = write_stl(tetra_stl(), "tetra.stl")
    glb_path = Path.join(Path.dirname(stl_path), "tetra.glb")
    assert :ok == Glb.write(stl_path, glb_path)

    {:ok, data} = File.read(glb_path)
    byte_size = :erlang.byte_size(data)

    <<magic::binary-size(4), version::little-unsigned-integer-size(32),
      total::little-unsigned-integer-size(32), json_len::little-unsigned-integer-size(32),
      json_type::little-unsigned-integer-size(32), json_bin::binary-size(json_len),
      bin_len::little-unsigned-integer-size(32), bin_type::little-unsigned-integer-size(32),
      bin_bin::binary-size(bin_len)>> = data

    assert magic == "glTF"
    assert version == 2
    assert total == byte_size
    assert json_type == 0x4E4F534A
    assert bin_type == 0x004E4942
    assert rem(json_len, 4) == 0
    assert rem(bin_len, 4) == 0
    assert 12 + 8 + json_len + 8 + bin_len == byte_size

    assert {:ok, json} = Jason.decode(json_bin)

    assert get_in(json, ["asset", "version"]) == "2.0"
    assert json["scene"] == 0
    assert [%{"nodes" => _}] = json["scenes"]
    assert [%{"mesh" => _}] = json["nodes"]
    assert [%{"primitives" => [prim]}] = json["meshes"]
    assert [%{"buffer" => 0, "byteLength" => bl}] = json["buffers"]

    assert [%{"buffer" => 0, "byteOffset" => 0, "byteLength" => iv_len} | rest] =
             json["bufferViews"]

    assert [%{"buffer" => 0, "byteOffset" => ^iv_len, "byteLength" => pv_len}] = rest

    [idx_acc, pos_acc] = json["accessors"]
    assert idx_acc["componentType"] == 5125
    assert idx_acc["type"] == "SCALAR"
    assert idx_acc["count"] == 12

    assert pos_acc["componentType"] == 5126
    assert pos_acc["type"] == "VEC3"
    assert pos_acc["count"] == 12
    assert prim["attributes"]["POSITION"] == 1
    assert prim["indices"] == 0

    assert bl == iv_len + pv_len
    assert byte_size(bin_bin) == bl

    # POSITION min/max bracket all vertex coordinates
    [x_min, y_min, z_min] = pos_acc["min"]
    [x_max, y_max, z_max] = pos_acc["max"]
    assert [x_min, y_min, z_min] == [0.0, 0.0, 0.0]
    assert [x_max, y_max, z_max] == [1.0, 1.0, 1.0]
  end

  test "Glb.write reports error for a bad STL" do
    bad = write_stl("not a stl at all", "bad.stl")
    assert {:error, _} = Glb.write(bad, Path.join(Path.dirname(bad), "bad.glb"))
  end

  # --- static gate -------------------------------------------------------------

  setup_all do
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  describe "execute/2 static gate" do
    test "rejects import()" do
      r = OpenScad.execute("import(\"x.stl\");", "owner-gate")
      refute r.ok
      assert r.stage == :static_check
      assert r.error =~ "import()"
      assert is_integer(r.exec_ms)
    end

    test "rejects surface()" do
      r = OpenScad.execute("surface(\"x.dat\");", "owner-gate")
      refute r.ok
      assert r.stage == :static_check
      assert r.error =~ "surface()"
    end

    test "rejects use <...> and include <...>" do
      for code <- ["use <lib.scad>", "  include <lib.scad>\n"] do
        r = OpenScad.execute(code, "owner-gate")
        refute r.ok
        assert r.stage == :static_check
        assert r.error =~ "include/use"
      end
    end

    test "rejects code over 20000 bytes" do
      r = OpenScad.execute(String.duplicate("c", 20_001), "owner-gate")
      refute r.ok
      assert r.stage == :static_check
      assert r.error =~ "20_000" or r.error =~ "20000" or r.error =~ "bytes"
    end
  end

  # --- end-to-end (skips without the openscad binary) ---------------------------

  @tag :openscad_integration
  @tag if(System.find_executable("openscad"),
         do: [],
         else: [skip: "openscad binary not installed"]
       )
  test "execute/2 runs openscad end to end" do
    owner = "owner-it-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Path.absname(Path.join(Mnft.Cad.Config.get(:models_dir), owner)) |> File.rm_rf!()
    end)

    r = OpenScad.execute("cube(30);", owner)
    assert r.ok, "expected ok, got: #{inspect(r)}"

    assert_in_delta Enum.at(r.mesh.bbox_mm, 0), 30.0, 0.01
    assert_in_delta Enum.at(r.mesh.bbox_mm, 1), 30.0, 0.01
    assert_in_delta Enum.at(r.mesh.bbox_mm, 2), 30.0, 0.01
    assert r.artifacts.step == nil
    assert File.exists?(r.artifacts.stl)
    assert r.artifacts.script =~ "model.scad"
    assert File.exists?(r.artifacts.script)
    assert r.artifacts.glb == nil or File.exists?(r.artifacts.glb)
    assert is_integer(r.exec_ms)
  end

  test "healthy? is a boolean" do
    assert is_boolean(OpenScad.healthy?())
  end
end

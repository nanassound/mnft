defmodule Mnft.Cad.StlTest do
  use ExUnit.Case, async: false

  alias Mnft.Cad.{Config, Stl, TestEvents}

  @stl_bytes <<0::size(84 * 8)>>
  @stl_url "data:model/stl;base64," <> Base.encode64(@stl_bytes)
  @sla_url "data:application/sla;base64," <> Base.encode64(@stl_bytes)

  # Analyzer output shape (from cad_worker.stlprofile on the hex pen holder).
  @profile %{
    "ok" => true,
    "stats" => %{
      "triangles" => 44,
      "vertices" => 24,
      "bbox_min" => [-23.094, -20.0, 0.0],
      "bbox_max" => [23.094, 20.0, 90.0],
      "bbox_size" => [46.188, 40.0, 90.0],
      "volume" => 37_609.7525,
      "area" => 25_488.86,
      "watertight" => true,
      "components" => 1
    },
    "sections" => [
      %{"axis" => "z", "offset" => 7.5,
        "loops" => [[[23.094, 0.0], [11.547, -20.0], [-11.547, -20.0], [-23.094, 0.0],
                     [-11.547, 20.0], [11.547, 20.0]]]},
      %{"axis" => "x", "offset" => 0.0,
        "loops" => [[[20.0, 0.0], [-20.0, 0.0], [-20.0, 90.0], [-17.0, 90.0],
                     [-17.0, 3.0], [17.0, 3.0], [17.0, 90.0], [20.0, 90.0]]]}
    ],
    "renders" => [Base.encode64("png-one"), Base.encode64("png-two")]
  }

  setup do
    snapshot = Config.all()
    TestEvents.set(self())

    on_exit(fn ->
      TestEvents.unset()
      Application.put_env(:mnft_cad, :cad, snapshot)
    end)

    :ok
  end

  defp set_profile(behavior) do
    cfg = Keyword.put(Config.all(), :stl_profile_fun, {__MODULE__, :profile_stub, []})
    Application.put_env(:mnft_cad, :cad, cfg)
    Application.put_env(:mnft_cad, :test_profile_behavior, behavior)
  end

  def profile_stub(_stl) do
    case Application.get_env(:mnft_cad, :test_profile_behavior) do
      {:ok, profile} -> {:ok, profile}
      {:error, reason} -> {:error, reason}
      :raise -> raise "boom in profile"
    end
  end

  # --- validate/1 ----------------------------------------------------------------

  test "validate: nil and empty map mean no upload" do
    assert Stl.validate(nil) == {:ok, nil}
    assert Stl.validate(%{}) == {:ok, nil}
  end

  test "validate: good model/stl data URL" do
    assert {:ok, %{data_url: @stl_url, name: "bracket.stl", size: 84}} =
             Stl.validate(%{"data_url" => @stl_url, "name" => "bracket.stl", "size" => 84})
  end

  test "validate: application/sla accepted, name defaults" do
    assert {:ok, %{name: "part.stl", size: 84}} = Stl.validate(%{"data_url" => @sla_url})
  end

  test "validate: wrong mime rejected" do
    url = "data:image/png;base64," <> Base.encode64(@stl_bytes)

    assert {:error, "stl: not a data:model/stl;base64 or data:application/sla;base64 URL"} =
             Stl.validate(%{"data_url" => url})
  end

  test "validate: oversize rejected with sizes named" do
    big = :binary.copy(<<0>>, 21 * 1_048_576)
    url = "data:model/stl;base64," <> Base.encode64(big)

    assert {:error, "stl: 21.0 MB attached, limit is 20.0 MB"} =
             Stl.validate(%{"data_url" => url})
  end

  test "validate: invalid base64 and non-map rejected" do
    # valid charset, but not a multiple of 4 -> decode fails
    assert {:error, "stl: payload is not valid base64"} =
             Stl.validate(%{"data_url" => "data:model/stl;base64,notbase64"})

    assert {:error, reason} = Stl.validate("nope")
    assert reason =~ "must be a map"
  end

  # --- format_block/2 --------------------------------------------------------------

  test "format_block: header, units, mesh, bbox, sections, footer" do
    block = Stl.format_block("bracket.stl", Jason.encode!(@profile))

    assert block =~ ~s([Uploaded STL mesh "bracket.stl" — reverse-engineer this part)
    assert block =~ "treat them as millimetres"
    assert block =~ "Mesh: 44 triangles, 1 body, watertight, volume 37,609.75, area 25,488.86."
    assert block =~ "Bounding box: x -23.09..23.09, y -20.0..20.0, z 0.0..90.0 (46.19 x 40.0 x 90.0)."
    assert block =~ "z=7.5: (23.09, 0.0) -> (11.55, -20.0) -> (-11.55, -20.0) -> (-23.09, 0.0)"
    assert block =~ "x=0.0: (20.0, 0.0) -> (-20.0, 0.0) -> (-20.0, 90.0) -> (-17.0, 90.0)"
    assert block =~ "[closes]"
    assert block =~ "Reconstruct the DESIGN INTENT"
    assert block =~ "dimensions you inferred.]"
  end

  test "format_block: garbage or empty JSON still yields header + footer, never \"\"" do
    for json <- ["", "not json", Jason.encode!(%{"stats" => "flat"})] do
      block = Stl.format_block("part.stl", json)
      assert String.starts_with?(block, "[Uploaded STL mesh \"part.stl\"")
      assert block =~ "DESIGN INTENT"
      refute block =~ "Mesh:"
      refute block =~ "z="
    end
  end

  test "format_block: open mesh and multi-body phrasing" do
    profile =
      @profile
      |> put_in(["stats", "watertight"], false)
      |> put_in(["stats", "components"], 3)

    block = Stl.format_block("part.stl", Jason.encode!(profile))
    assert block =~ "Mesh: 44 triangles, 3 bodies, not watertight,"
  end

  test "format_block: caps by dropping trailing sections" do
    cfg = Keyword.put(Config.all(), :stl, max_block_chars: 900)
    Application.put_env(:mnft_cad, :cad, cfg)

    block = Stl.format_block("part.stl", Jason.encode!(@profile))
    assert block =~ "[1 later sections omitted]"
    assert block =~ "z=7.5:"
    refute block =~ "x=0.0:"
  end

  # --- attach/3 --------------------------------------------------------------------

  @stl_map %{"data_url" => @stl_url, "name" => "bracket.stl", "size" => 84}

  test "attach: no upload is a no-op without events" do
    assert Stl.attach("s1", "make a cube", nil) == {"make a cube", [], nil}
    assert Stl.attach("s1", "make a cube", %{}) == {"make a cube", [], nil}
    refute_received %{event: "stl_started"}
  end

  test "attach: success appends block, returns labeled renders and meta, emits events" do
    set_profile({:ok, @profile})

    {msg, images, meta} = Stl.attach("s1", "reverse this", @stl_map)

    assert msg =~ "reverse this\n\n[Uploaded STL mesh \"bracket.stl\""
    assert length(images) == 2

    for img <- images do
      assert %{media_type: "image/png", size: 7, label: "stl"} = img
      assert String.starts_with?(img.data_url, "data:image/png;base64,")
    end

    assert meta == %{
             name: "bracket.stl",
             bytes: 84,
             triangles: 44,
             bbox_size: [46.188, 40.0, 90.0],
             volume: 37_609.7525,
             components: 1,
             watertight: true
           }

    assert_received %{event: "stl_started", payload: %{name: "bracket.stl"}}
    assert_received %{event: "stl_done", payload: %{ok: true, triangles: 44, components: 1}}
  end

  test "attach: failure appends a note, no images, error meta, turn proceeds" do
    set_profile({:error, "corrupt binary STL (declared 12 triangles, room for 3)"})

    {msg, images, meta} = Stl.attach("s1", "reverse this", @stl_map)

    assert msg =~
             "[The attached STL could not be analyzed (corrupt binary STL " <>
               "(declared 12 triangles, room for 3)) — ask the user to re-export " <>
               "it as binary or ASCII STL]"

    assert images == []
    assert meta == %{name: "bracket.stl", bytes: 84, error: "corrupt binary STL (declared 12 triangles, room for 3)"}

    assert_received %{event: "stl_started"}
    assert_received %{event: "stl_done", payload: %{ok: false, reason: reason}}
    assert reason =~ "corrupt binary STL"
  end

  test "attach: a raising profile fun becomes an error, never a crash" do
    set_profile(:raise)

    {_msg, images, meta} = Stl.attach("s1", "reverse this", @stl_map)

    assert images == []
    assert meta.error =~ "boom in profile"
  end

  # --- run_profile/1 ----------------------------------------------------------------

  test "run_profile: invalid base64 errors before any subprocess" do
    assert {:error, "stl: payload is not valid base64"} =
             Stl.run_profile(%{"data_url" => "data:model/stl;base64,not-base64!"})
  end

  test "run_profile: missing python resolves to an error" do
    cfg =
      Config.all()
      |> Keyword.put(:stl, python_bin: "/nonexistent/venv/bin/python")
      |> Keyword.delete(:stl_profile_fun)

    Application.put_env(:mnft_cad, :cad, cfg)

    assert {:error, reason} = Stl.run_profile(@stl_map)
    assert reason =~ "python not found"
  end
end

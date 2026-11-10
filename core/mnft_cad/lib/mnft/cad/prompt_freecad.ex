defmodule Mnft.Cad.PromptFreecad do
  @moduledoc """
  The FreeCAD-dialect system prompt for the freecad geometry node pilot
  (routed only to pilot accounts; the default dialect stays build123d).
  Mirrors `Mnft.Cad.Prompt`'s interface (`system/0`, `skills_block/0`, the
  four image labels) so `ServerRunner` can swap the pair
  `{node_url, prompt_module}` without branching at every use site.

  The closing "Iteration discipline" block carries the same lesson as the
  build123d prompt's: edits must preserve everything the user did not ask to
  change — on FreeCAD we can verify that mechanically (bbox diff per axis),
  so the prompt asks for named parameters the runner can re-emit.
  """

  @system ~S"""
  You are a CAD assistant that writes FreeCAD Python code (FreeCAD 1.1,
  headless `freecadcmd`, Python 3.11).

  Reply with 1-3 plain sentences of explanation, then exactly one fenced
  ```python code block.

  The Python code must:
  - start with `import FreeCAD as App` followed by `import Part` and
    `import math`, and be fully self-contained;
  - be deterministic (same input, same model);
  - use millimetre units, centre the model on X/Y and put its base on Z=0;
  - create one document: `doc = App.newDocument("model")`, and bind the final
    shape to the LAST `Part::Feature` you add (the runner treats it as the
    artifact):
      result = doc.addObject("Part::Feature", "part")
      result.Shape = final_shape
      doc.recompute()
  - name every tunable dimension as a module-level parameter with a
    `# param:<name>` comment (e.g. `W = 90.0  # param:width`) so the runner
    can re-emit the script with changed values;
  - import nothing beyond FreeCAD/Part/math;
  - contain no file I/O, no `open(`, no os/sys/subprocess/socket/requests/
    urllib/importlib/ctypes/pickle, no eval/exec/__import__, no random, and
    no loop that could fail to terminate;
  - stay under ~120 lines.

  Allowed vocabulary (use only these):
  - Primitives: `Part.makeBox(w,d,h,Vector(x,y,z))`,
    `Part.makeCylinder(r,h,base,dir)`, `Part.makeSphere(r,center)`,
    `Part.makeCone(r1,r2,h,base,dir)`, `Part.makeTorus(r1,r2,center,dir)`
  - 2D: `Part.makeCircle(r,center,normal)`, `Part.makePolygon([Vector,...])`,
    `Part.Wire(edges)`, `Part.makePlane(w,d,base,normal)`
  - Booleans: `a.fuse(b)`, `a.cut(b)`, `a.common(b)`, `a.removeSplitter()`
  - Transforms: `shape.translate(v)`, `shape.rotate(base,dir,degrees)`,
    `shape.mirror(base,normal)`
  - Features: `shape.makeThickness(faces_to_remove, -wall, tol)` (NEGATIVE
    offset shells inward), `shape.makeFillet(r,edges)`,
    `shape.makeChamfer(r,edges)`,
    `Part.Wire(pathEdges).makePipeShell([profile], True, True)`
  - Helix: `Part.makeHelix(pitch, height, radius)` (add `lefthand=True` for
    left-hand). Sweep a profile whose plane is perpendicular to the path
    tangent at its start — for helices: circle centred at `(radius,0,0)`
    with normal `(0,1,0)`, then Frenet sweep as above.
  - Document objects: `doc.addObject("Part::Box"|"Part::Cylinder"|...)` then
    set `Length/Width/Height/Radius` attributes and position via
    `obj.Placement.Base = App.Vector(x,y,z)` (1.1 has NO `.X/.Y/.Z`
    setters), then `doc.recompute()`.

  FreeCAD gotchas (hit in production — follow exactly):
  - primitives expose NO `.X/.Y/.Z` attributes; only `Placement.Base`.
  - `makeThickness` wants the offset NEGATIVE to shell inward.
  - fusing document objects requires taking `.Shape` explicitly — but
    PREFER `Part.make*` shapes for boolean chains and add only ONE final
    `Part::Feature`; document primitives (PrimitivePy) have NO
    fuse/cut/common methods.
  - hex pockets and prismatic cuts: `Part.Face(Part.makePolygon(pts +
    [pts[0]])).extrude(App.Vector(0, 0, depth))` — there is no
    `Part.makePrism` in headless FreeCAD.
  - hole cutters must pass 5 mm beyond both faces (set `Placement.Base` /
    height accordingly) so cuts stay clean.
  - minimum wall thickness 1.6 mm for FDM unless the user says otherwise.
  - dimensions from the user are verbatim — never round or invent values;
    a cavity around a stated board clears it by 0.4 mm per side unless
    told otherwise.
  - Threads (M-series screws, bolts, tapped holes) MUST be modelled when
    the spec or drawing shows them — the kernel handles helical sweeps
    fine. PROVEN recipe (validated on FreeCAD 1.1.4 headless; M5x0.8
    external thread on a Ø5 shank — adapt radii/pitch per size):

        import math
        pitch = 0.8                    # ISO coarse: M3 0.5, M4 0.7, M5 0.8,
                                       # M6 1.0, M8 1.25, M10 1.5
        r_minor = (5.0 - 1.0825 * pitch) / 2.0   # minor radius ~2.06
        shank = Part.makeCylinder(r_minor, length)
        helix = Part.makeHelix(pitch, length + pitch, r_minor)
        profile = Part.makePolygon([
            App.Vector(r_minor, 0, -pitch * 0.35),
            App.Vector(r_minor + 0.45, 0, 0.0),   # crest ≈ major radius
            App.Vector(r_minor, 0, pitch * 0.35),
            App.Vector(r_minor, 0, -pitch * 0.35)])
        thread = Part.Wire(helix.Edges).makePipeShell(
            [Part.Wire(profile)], True, True)
        thread = thread.common(Part.makeBox(
            20, 20, length, App.Vector(-10, -10, 0)))   # flush ends
        body = shank.fuse(thread).removeSplitter()

    Hex socket pocket: `Part.Face(Part.makePolygon(pts + [pts[0]])).extrude(
    App.Vector(0, 0, depth))` with pts on a circle of radius =
    across_flats / sqrt(3), then `cut`. M4 Allen key = 4 mm across flats.

  Iteration discipline — edits must be surgical:
  When the conversation already contains a previous script and the user asks
  for a change, RE-EMIT the whole script with ONLY the requested values
  changed; keep every other parameter, feature and comment byte-identical.
  Never rename variables, reorder features, or restyle code that was not
  asked about — the runner diffs the bounding box per axis and rejects
  builds that moved in dimensions the user did not mention.
  """

  @skills_block """
  # FreeCAD dialect notes (freecad geometry node pilot)

  - The runner measures your result (volume, bbox, watertightness) and can
    verify an edit preserved untouched dimensions — say what you changed and
    why in the reply sentences.
  - Units are millimetres; the reference facts quoted in the prompt (if any)
    are the ground truth to hit, not stylistic suggestions.
  - Exports (STL/STEP) are produced by the runner — do not write files.
  """

  @doc "The FreeCAD-dialect system prompt."
  def system, do: @system

  @doc "Static discipline block (no skill dir scan in the pilot)."
  def skills_block, do: @skills_block

  @doc "Short text label placed before each reference image part, verbatim."
  def reference_image_label, do: "Reference photo from the user:"

  @doc "Short text label placed before each carried photo from an earlier turn, verbatim."
  def earlier_photo_label, do: "Reference photo from earlier in this conversation:"

  @doc "Short text label placed before each uploaded-STL render part, verbatim."
  def stl_render_label, do: "Uploaded STL mesh render:"

  @doc "Label for the attached render of the current model, verbatim."
  def current_render_label,
    do:
      "Our current model, rendered (do not copy the render's styling — this is what we have so far):"
end

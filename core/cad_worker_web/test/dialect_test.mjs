// Node smoke tests for the mnft replicad dialect. These run the exact same
// dialect module and OCCT wasm kernel that the browser worker uses
// (replicad works unmodified in Node), so a green run here proves the
// dialect harness, static checks, and STL/STEP exports end-to-end.
import { test } from "node:test";
import assert from "node:assert/strict";
import { loadOpenCascade } from "../oc.js";
import { staticCheck, run, ALLOWED_IMPORTS, SHAPE_NAMES } from "../dialects/replicad.js";
import { SAMPLE_PART } from "../examples/sample_part.js";

// Expected volume of the sample part from first principles:
//   regular hexagon area with apothem a: A = 2*sqrt(3)*a^2
//   part = outer full height  MINUS  inner shifted up by the wall:
//   V = A_out * height - A_in * (height - wall)
const ACROSS = 40.0;
const WALL = 3.0;
const HEIGHT = 90.0;
const hexArea = (across) => 2 * Math.sqrt(3) * (across / 2) ** 2;
const EXPECTED_VOLUME =
  hexArea(ACROSS) * HEIGHT - hexArea(ACROSS - 2 * WALL) * (HEIGHT - WALL);

test("kernel loads and injects into replicad", async () => {
  const { ms } = await loadOpenCascade();
  assert.ok(ms >= 0);
});

test("sample part: correct volume, STL and STEP exported", async () => {
  const res = await run(SAMPLE_PART);
  assert.equal(res.ok, true, res.error ?? "run failed");

  assert.equal(res.pickedFrom, "part");
  assert.ok(res.stats.volumeMM3 > 0, "volume must be positive");
  const relErr =
    Math.abs(res.stats.volumeMM3 - EXPECTED_VOLUME) / EXPECTED_VOLUME;
  assert.ok(relErr < 0.01, `volume ${res.stats.volumeMM3} vs expected ${EXPECTED_VOLUME}`);

  // bbox: 40 mm across x, full outer height (the part keeps the outer 0..90)
  const bb = res.stats.bboxMM;
  assert.ok(Math.abs(bb.max[2] - HEIGHT) < 1e-6, JSON.stringify(bb));

  // binary STL: >= 84-byte header + 50 bytes per triangle
  const stlBuf = Buffer.from(await res.stl.arrayBuffer());
  const triCount = stlBuf.readUInt32LE(80);
  assert.equal(triCount, res.stats.triangles);
  assert.ok(
    stlBuf.length >= 84 + 50 * triCount,
    `STL size ${stlBuf.length} too small for ${triCount} triangles`,
  );

  // STEP text header
  const stepText = await res.step.text();
  assert.ok(stepText.includes("ISO-10303-21"), "STEP must be a valid STEP file");
});

test("static checks reject disallowed imports and host access", () => {
  for (const [code, needle] of [
    ["import os from \"os\";", "not allowed"],
    ["import { readFileSync } from \"node:fs\";", "not allowed"],
    ["const fs = require(\"fs\");", "require"],
    ["import(\"fs\").then(() => {});", "dynamic import"],
    ["export const part = 1;", "export"],
    ["const x = process.env.HOME;", "process"],
    ["eval(\"1+1\");", "eval"],
  ]) {
    const res = staticCheck(code);
    assert.equal(res.ok, false, `should reject: ${code}`);
    assert.ok(res.error.includes(needle), `${code} -> ${res.error}`);
  }

  // allowed: the dialect itself, and math-free shape code
  assert.equal(staticCheck("import { makePolygon } from \"replicad\";").ok, true);
  assert.equal(staticCheck("const part = 1;").ok, true);
});

test("syntax errors are reported, not thrown", async () => {
  const res = await run("const part = ;");
  assert.equal(res.ok, false);
  assert.match(res.error, /SyntaxError/);
});

test("runtime errors are reported with the message", async () => {
  const res = await run("throw new RangeError(\"bad radius\");");
  assert.equal(res.ok, false);
  assert.match(res.error, /RangeError: bad radius/);
});

test("missing shape variable produces the convention error", async () => {
  const res = await run("const box = 1;");
  assert.equal(res.ok, false);
  assert.match(res.error, /no shape named 'part'/);
  for (const name of SHAPE_NAMES) {
    assert.match(res.error, new RegExp(name));
  }
});

test("math namespace mirrors the Python harness pre-bindings", async () => {
  const code = `
    const r = tan(radians(45));
    const c = copysign(3, -1);
    const part = sketchRectangle(10, 10).extrude(2 * floor(pi));
  `;
  const res = await run(code);
  assert.equal(res.ok, true, res.error);
  // floor(pi) = 3 -> height 6
  assert.ok(Math.abs(res.stats.bboxMM.max[2] - 6) < 1e-6);
});

test("assembly: array of shapes is accepted", async () => {
  // NOTE: replicad's translate() is destructive (the source shape is freed),
  // so assemblies must place independently-built shapes — mirroring the
  // gotchas the dialect quickref has to teach, like build123d's own idioms.
  const code = `
    const a = sketchRectangle(10, 10).extrude(5);
    const b = sketchRectangle(10, 10).extrude(5).translate(20, 0, 0);
    const assembly = [a, b];
  `;
  const res = await run(code);
  assert.equal(res.ok, true, res.error);
  assert.equal(res.pickedFrom, "assembly");
  // sketchRectangle is centre-origin: a spans -5..5, b spans 15..25
  assert.ok(Math.abs(res.stats.bboxMM.max[0] - 25) < 1e-6, JSON.stringify(res.stats.bboxMM));
});

// replicad dialect — the web twin of cad_worker's build123d dialect
// (cad_worker/cad_worker/dialects/build123d.py).
//
// Same contract, same philosophy:
//   1. static checks before anything runs (import allowlist, no exports,
//      no host-object reach),
//   2. user code runs in a bare namespace seeded with the dialect API and
//      math helpers (like `from build123d import *` plus the pre-bound
//      math names in the Python harness),
//   3. the result is picked by convention: `part`, then `result`,
//      `assembly`, `obj`,
//   4. exports are STL (binary), STEP, and a viewer mesh — the three
//      formats the mnft pipeline promises.
//
// Guard rails differ from Python by platform: the Python worker has
// rlimits + a wall clock; in the browser the sandbox is the Web Worker and
// the wall clock is a page-side watchdog that terminates the worker.

import * as replicad from "replicad";
import { exportShapeSTL, exportShapeSTEP } from "replicad/shape-functions";
import { parse } from "acorn";
import { simple as walk } from "acorn-walk";

export const DIALECT = "replicad";
export const ALLOWED_IMPORTS = new Set(["replicad"]);
export const SHAPE_NAMES = ["part", "result", "assembly", "obj"];

// ---------------------------------------------------------------------------
// Static checks
// ---------------------------------------------------------------------------

export function staticCheck(code) {
  let ast;
  try {
    ast = parse(code, { ecmaVersion: "latest", sourceType: "module" });
  } catch (err) {
    return { ok: false, error: `SyntaxError: ${err.message}` };
  }

  const problems = [];
  const deny = (msg, node) =>
    problems.push(`line ${node.loc?.start.line ?? "?"}: ${msg}`);

  walk(ast, {
    ImportDeclaration(node) {
      const src = node.source.value;
      if (!ALLOWED_IMPORTS.has(src)) {
        deny(
          `import of "${src}" is not allowed (allowed: ${[...ALLOWED_IMPORTS].join(", ")})`,
          node,
        );
      }
    },
    ImportExpression(node) {
      deny("dynamic import() is not allowed", node);
    },
    ExportNamedDeclaration(node) {
      deny("export is not allowed in dialect code", node);
    },
    ExportDefaultDeclaration(node) {
      deny("export is not allowed in dialect code", node);
    },
    CallExpression(node) {
      if (node.callee.type === "Identifier" && node.callee.name === "require") {
        deny("require() is not allowed", node);
      }
      if (node.callee.type === "Identifier" && node.callee.name === "eval") {
        deny("eval() is not allowed", node);
      }
    },
    MemberExpression(node) {
      if (
        node.object.type === "Identifier" &&
        ["globalThis", "global", "window", "document", "self", "process"].includes(
          node.object.name,
        )
      ) {
        deny(`access to "${node.object.name}" is not allowed`, node);
      }
    },
  });

  if (problems.length) {
    return { ok: false, error: "static check failed:\n  - " + problems.join("\n  - ") };
  }
  return { ok: true };
}

// ---------------------------------------------------------------------------
// Namespace — math helpers mirror the Python harness pre-bindings
// ---------------------------------------------------------------------------

export function buildNamespace() {
  // Mirror the Python harness pre-bindings: math under `math`, plus the
  // common bare names. Bare trig/log names are NOT globals in JS (they live
  // on Math), so the dialect binds them explicitly, like `from math import *`.
  const ns = {
    math: Math,
    pi: Math.PI,
    e: Math.E,
    tau: Math.PI * 2,
    sin: Math.sin,
    cos: Math.cos,
    tan: Math.tan,
    asin: Math.asin,
    acos: Math.acos,
    atan: Math.atan,
    atan2: Math.atan2,
    sinh: Math.sinh,
    cosh: Math.cosh,
    tanh: Math.tanh,
    sqrt: Math.sqrt,
    exp: Math.exp,
    log: Math.log,
    log10: Math.log10,
    floor: Math.floor,
    ceil: Math.ceil,
    trunc: Math.trunc,
    hypot: Math.hypot,
    radians: (deg) => (deg * Math.PI) / 180,
    degrees: (rad) => (rad * 180) / Math.PI,
    fabs: Math.abs,
    copysign: (x, y) => (y < 0 || Object.is(y, -0) ? -Math.abs(x) : Math.abs(x)),
    fmod: (x, y) => x % y,
    modf: (x) => [Math.trunc(x), x - Math.trunc(x)],
    isclose: (a, b, opts = {}) => {
      const relTol = opts.relTol ?? opts.rel_tol ?? 1e-9;
      const absTol = opts.absTol ?? opts.abs_tol ?? 0.0;
      return (
        Math.abs(a - b) <=
        Math.max(relTol * Math.max(Math.abs(a), Math.abs(b)), absTol)
      );
    },
    dist: (p, q) => {
      let acc = 0;
      for (let i = 0; i < Math.min(p.length, q.length); i++) acc += (p[i] - q[i]) ** 2;
      return Math.sqrt(acc);
    },
  };
  // Bare-name dialect API — the JS equivalent of `from build123d import *`.
  for (const [name, value] of Object.entries(replicad)) {
    if (name === "setOC" || name === "setFromOC" || name.startsWith("_")) continue;
    ns[name] = value;
  }
  return ns;
}

// ---------------------------------------------------------------------------
// Shape picking + result assembly
// ---------------------------------------------------------------------------

function isShape(v) {
  return (
    v instanceof replicad.Shape ||
    (v !== null &&
      typeof v === "object" &&
      typeof v.mesh === "function" &&
      typeof v.boundingBox !== "undefined")
  );
}

export function pickShape(ns) {
  for (const name of SHAPE_NAMES) {
    const val = ns[name];
    if (isShape(val)) return { ok: true, shape: val, from: name };
    if (Array.isArray(val) && val.length && val.every(isShape)) {
      return { ok: true, shape: replicad.compoundShapes(val), from: name };
    }
  }
  const found = Object.keys(ns).filter((k) => isShape(ns[k])).sort();
  return {
    ok: false,
    error:
      `no shape named 'part' (or ${SHAPE_NAMES.slice(1).join("/")}) was defined; ` +
      `shape-like names found: ${found.join(", ") || "none"}`,
  };
}

export async function run(code, options = {}) {
  const t0 = performance.now();

  const check = staticCheck(code);
  if (!check.ok) return { ok: false, error: check.error };

  const ns = buildNamespace();
  const keys = Object.keys(ns);
  // Unlike Python's exec(ns), `const part = ...` inside new Function is a
  // local binding the caller cannot see. So we append a capture tail that
  // returns the shape-candidate names by convention — the JS equivalent of
  // the Python harness reaching into the exec namespace.
  const captureTail =
    "\n;return {" +
    SHAPE_NAMES.map(
      (n) => `${n}: typeof ${n} === "undefined" ? undefined : ${n}`,
    ).join(", ") +
    "};";
  try {
    const fn = new Function(...keys, code + captureTail);
    const captured = fn(...keys.map((k) => ns[k]));
    for (const [k, v] of Object.entries(captured ?? {})) {
      if (v !== undefined) ns[k] = v;
    }
  } catch (err) {
    return { ok: false, error: `${err.name || "Error"}: ${err.message}` };
  }

  const picked = pickShape(ns);
  if (!picked.ok) return { ok: false, error: picked.error };
  const shape = picked.shape;

  const tolerance = options.tolerance ?? 0.15;
  const angularTolerance = options.angularTolerance ?? 0.25;

  let meshRaw;
  try {
    meshRaw = shape.mesh({ tolerance, angularTolerance });
  } catch (err) {
    return { ok: false, error: `meshing failed: ${err.message ?? err}` };
  }

  const bb = shape.boundingBox;
  const bboxMM = {
    min: [...bb.bounds[0]],
    max: [...bb.bounds[1]],
  };

  let volumeMM3 = null;
  try {
    volumeMM3 = replicad.measureShapeVolumeProperties(shape)?.volume ?? null;
  } catch {
    /* surfaces have no volume; leave null */
  }

  let stl;
  let step;
  try {
    stl = await exportShapeSTL(shape, { tolerance, angularTolerance, binary: true });
    step = await exportShapeSTEP(shape);
  } catch (err) {
    return { ok: false, error: `export failed: ${err.message ?? err}` };
  }

  return {
    ok: true,
    dialect: DIALECT,
    pickedFrom: picked.from,
    stats: { volumeMM3, bboxMM, triangles: Math.floor(meshRaw.triangles.length / 3) },
    meshRaw,
    stl,
    step,
    elapsedMs: performance.now() - t0,
  };
}

// oc.js — single place where the OCCT-in-WASM kernel is loaded and injected
// into replicad. Used by the browser worker and by the Node test suite, so
// both exercise the exact same kernel build (replicad-opencascadejs).
import { setOC } from "replicad";

let instancePromise = null;

export function loadOpenCascade() {
  if (!instancePromise) {
    instancePromise = (async () => {
      const mod = await import("replicad-opencascadejs");
      const factory = mod.default ?? mod;
      const t0 = performance.now();
      const oc = await factory();
      setOC(oc);
      return { ms: performance.now() - t0 };
    })();
  }
  return instancePromise;
}

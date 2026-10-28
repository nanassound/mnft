import { defineConfig } from "vite";

// The worker loads the OCCT kernel via dynamic import → code-splitting, which
// requires ES worker format (vite's default iife cannot code-split). The
// emscripten glue resolves its .wasm via import.meta.url, which breaks under
// vite's dep pre-bundling (the request falls through to the SPA fallback and
// gets index.html back) — so the kernel package must be excluded.
export default defineConfig({
  worker: { format: "es" },
  optimizeDeps: { exclude: ["replicad-opencascadejs"] },
});

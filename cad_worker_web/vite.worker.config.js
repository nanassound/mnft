import { defineConfig } from "vite";

// Standalone build of the dialect worker for the mnft_browser host app:
// `npm run build:worker` emits dist-host/, which `mix host.assets` copies to
// mnft_browser/public/kernel/. Same constraints as vite.config.js: ES worker
// format so the kernel's dynamic import can code-split, and the kernel
// package excluded from dep pre-bundling (the emscripten glue resolves its
// .wasm via import.meta.url). The manifest is emitted so the host page can
// resolve the hashed worker entry without hardcoding it.
export default defineConfig({
  worker: { format: "es" },
  // The host serves this build under /kernel/ (mix host.assets copies
  // dist-host/ there), so the emscripten glue's wasm URL must be rewritten
  // with that prefix — the default "/" makes it 404.
  base: "/kernel/",
  build: {
    outDir: "dist-host",
    target: "esnext",
    assetsInlineLimit: 0,
    manifest: true,
    rollupOptions: { input: { worker: "worker.js" } },
  },
  optimizeDeps: { exclude: ["replicad-opencascadejs"] },
});

// Browser worker for the mnft replicad dialect. The worker IS the sandbox:
// dialect code runs here, off the main thread, with a hard isolation
// boundary — a runaway model can only be killed by terminating the worker,
// which the page does via its watchdog.
//
// Message protocol
//   → { type: "run", id, code, tolerance?, angularTolerance? }
//   ← { type: "ready", kernelMs }
//   ← { id, ok: true, dialect, pickedFrom, stats, elapsedMs,
//       positions: ArrayBuffer, triangles: ArrayBuffer,
//       stl: ArrayBuffer, step: string }
//   ← { id, ok: false, error }
import { loadOpenCascade } from "./oc.js";
import { run } from "./dialects/replicad.js";

// Warm the kernel the moment the worker exists — the page shows progress
// while the ~9 MB (brotli) OCCT build streams in.
const kernel = loadOpenCascade();
kernel
  .then(({ ms }) => self.postMessage({ type: "ready", kernelMs: Math.round(ms) }))
  .catch((err) => self.postMessage({ type: "kernel-error", error: String(err) }));

self.onmessage = async (event) => {
  const { type, id, code, tolerance, angularTolerance } = event.data ?? {};
  if (type !== "run") return;

  try {
    await kernel; // OC is set inside loadOpenCascade before this resolves
    const res = await run(code, { tolerance, angularTolerance });
    if (!res.ok) {
      self.postMessage({ id, ok: false, error: res.error });
      return;
    }

    const positions = new Float32Array(res.meshRaw.vertices).buffer;
    const triangles = new Uint32Array(res.meshRaw.triangles).buffer;
    const stl = await res.stl.arrayBuffer();

    self.postMessage(
      {
        id,
        ok: true,
        dialect: res.dialect,
        pickedFrom: res.pickedFrom,
        stats: res.stats,
        elapsedMs: Math.round(res.elapsedMs),
        positions,
        triangles,
        stl,
        step: await res.step.text(),
      },
      [positions, triangles, stl],
    );
  } catch (err) {
    self.postMessage({ id, ok: false, error: String(err?.stack || err) });
  }
};

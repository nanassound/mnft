// mnft browser core — page glue.
//
// This tab runs BOTH halves of the CAD pipeline:
//   * the core (turn pipeline, sessions, ETS store, scripted/BYOK LLM) as
//     BEAM-in-WASM, reached via `popcorn.tryCall("mnft_kernel", […])`,
//   * the geometry kernel: the cad_worker_web replicad worker on OCCT wasm,
//     driven by the core's `MnftBrowser.Engines.Replicad` through
//     `window.__mnftEngine.run(code, id, pid, cast)`.
// Mesh/STL/STEP bytes stay here (window.__mnftArtifacts), keyed by the run
// id the engine uses as its `mem://` artifact handle.

import * as THREE from "three";
import { OrbitControls } from "/vendor/three/OrbitControls.js";
import { Popcorn } from "/out/index.mjs";

const $ = (sel) => document.querySelector(sel);
const el = {
  vm: $("#chip-vm"),
  engine: $("#chip-engine"),
  journal: $("#chip-journal"),
  llm: $("#chip-llm"),
  occt: $("#chip-occt"),
  session: $("#chip-session"),
  transcript: $("#transcript"),
  hint: $("#transcript-hint"),
  stages: $("#stages"),
  prompt: $("#prompt"),
  run: $("#run"),
  viewport: $("#viewport-wrap"),
  downloads: $("#downloads"),
  statTris: $("#stat-tris"),
  statBbox: $("#stat-bbox"),
  statVol: $("#stat-vol"),
  statMs: $("#stat-ms"),
  settings: $("#settings"),
  provider: $("#set-provider"),
  base: $("#set-base"),
  key: $("#set-key"),
  model: $("#set-model"),
  save: $("#set-save"),
  settingsStatus: $("#settings-status"),
};

const turnInFlight = () => el.run.disabled && el.prompt.disabled;

function setTurnInFlight(on) {
  el.run.disabled = on || !workerReady;
  el.prompt.disabled = on;
}

// ---------------------------------------------------------------------------
// three.js viewer (port of cad_worker_web/main.js)
// ---------------------------------------------------------------------------
const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setPixelRatio(window.devicePixelRatio);
el.viewport.appendChild(renderer.domElement);

const scene = new THREE.Scene();
scene.background = new THREE.Color(0x14161c);

const camera = new THREE.PerspectiveCamera(45, 1, 0.1, 5000);
const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;

scene.add(new THREE.HemisphereLight(0xffffff, 0x2a2d35, 2.2));
const key = new THREE.DirectionalLight(0xffffff, 1.6);
key.position.set(120, 180, 120);
scene.add(key);
const grid = new THREE.GridHelper(400, 40, 0x3a3f4d, 0x23262e);
scene.add(grid);

function resize() {
  const w = el.viewport.clientWidth;
  const h = el.viewport.clientHeight;
  renderer.setSize(w, h, false);
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
  controls.update();
  renderer.render(scene, camera);
}
window.addEventListener("resize", resize);

function showModel(positions, triangles, bbox) {
  for (const child of [...scene.children]) {
    if (child.userData.model) scene.remove(child);
  }
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute("position", new THREE.BufferAttribute(new Float32Array(positions), 3));
  geometry.setIndex(new THREE.BufferAttribute(new Uint32Array(triangles), 1));
  geometry.computeVertexNormals();

  const material = new THREE.MeshStandardMaterial({
    color: 0xf5a524,
    metalness: 0.15,
    roughness: 0.55,
    side: THREE.DoubleSide,
  });
  const mesh = new THREE.Mesh(geometry, material);
  mesh.userData.model = true;
  scene.add(mesh);

  const size = new THREE.Vector3(
    bbox.max[0] - bbox.min[0],
    bbox.max[1] - bbox.min[1],
    bbox.max[2] - bbox.min[2],
  );
  const center = new THREE.Vector3(
    (bbox.min[0] + bbox.max[0]) / 2,
    (bbox.min[1] + bbox.max[1]) / 2,
    (bbox.min[2] + bbox.max[2]) / 2,
  );
  const radius = Math.max(size.x, size.y, size.z) || 1;

  controls.target.copy(center);
  camera.position.set(center.x + radius * 1.8, center.y + radius * 1.6, center.z + radius * 1.8);
  camera.near = radius / 100;
  camera.far = radius * 100;
  camera.updateProjectionMatrix();
  controls.update();
  resize();
}

// ---------------------------------------------------------------------------
// replicad worker sandbox (adapted from cad_worker_web/main.js): the worker
// IS the sandbox; a runaway model is stopped by the 30 s watchdog, which
// terminates + respawns it and reports the run as failed.
// ---------------------------------------------------------------------------
const WATCHDOG_MS = 30_000;

let worker = null;
let workerUrl = null;
let workerReady = false;
let runTimer = null;

const pending = new Map(); // run id → BEAM pid awaiting the result
window.__mnftArtifacts = {}; // run id → {positions, triangles, stl, step}

async function ensureWorker() {
  if (worker) return;
  if (!workerUrl) {
    // Hashed entry names change on every rebuild: never serve a stale manifest.
    const manifest = await (await fetch("/kernel/.vite/manifest.json", { cache: "no-store" })).json();
    const entry = manifest["worker.js"] ?? Object.values(manifest).find((e) => e.isEntry);
    if (!entry?.file) throw new Error("worker entry not found in /kernel/.vite/manifest.json");
    workerUrl = "/kernel/" + entry.file;
  }
  worker = new Worker(workerUrl, { type: "module" });
  worker.onmessage = (event) => {
    const data = event.data;
    if (data.type === "ready") {
      workerReady = true;
      el.occt.textContent = `OCCT ready (${data.kernelMs} ms)`;
      el.occt.dataset.on = "true";
      if (!turnInFlight()) el.run.disabled = false;
    } else if (data.type === "kernel-error") {
      workerReady = false;
      el.occt.textContent = "OCCT failed";
      el.occt.dataset.err = "true";
      console.error("[kernel]", data.error);
    } else if (pending.has(data.id)) {
      const { send } = pending.get(data.id);
      pending.delete(data.id);
      disarmWatchdog();
      if (data.ok) {
        // Bytes stay in the page; only the small stats cross into the BEAM.
        window.__mnftArtifacts[data.id] = {
          positions: data.positions,
          triangles: data.triangles,
          stl: data.stl,
          step: data.step,
          bbox: data.stats?.bboxMM ?? null,
        };
        send && sendResult(send, data.id, {
          ok: true,
          stage: "exec",
          stats: data.stats,
          elapsedMs: data.elapsedMs,
        });
      } else {
        send && sendResult(send, data.id, {
          ok: false,
          stage: data.stage || "exec",
          error: data.error,
          elapsedMs: data.elapsedMs || 0,
        });
      }
    }
  };
  worker.onerror = (event) => {
    workerReady = false;
    el.occt.textContent = "OCCT failed";
    el.occt.dataset.err = "true";
    console.error("[worker]", event.message);
  };
}

function terminateWorker() {
  if (runTimer) {
    clearTimeout(runTimer);
    runTimer = null;
  }
  worker?.terminate();
  worker = null;
  workerReady = false;
}

// `send` is popcorn's raw-delivery action with a NAME target: the
// EngineMailbox process receives {:wasm, payload} directly (a pid target is
// not accepted, and a proxy cast would arrive GenServer-wrapped).
function sendResult(send, id, result) {
  Promise.resolve(send(MAILBOX_TARGET, ["engine_result", id, result])).catch((err) =>
    console.error("[engine-result]", err),
  );
}

function disarmWatchdog() {
  clearTimeout(runTimer);
  runTimer = null;
}

function armWatchdog(id) {
  clearTimeout(runTimer);
  runTimer = setTimeout(() => {
    const entry = pending.get(id);
    pending.delete(id);
    terminateWorker();
    ensureWorker();
    entry?.send && sendResult(entry.send, id, {
      ok: false,
      stage: "exec",
      error: "watchdog: execution exceeded 30 s and was terminated",
      elapsedMs: 30000,
    });
  }, WATCHDOG_MS);
}

// The engine's entry point, called from inside the WASM BEAM via JS.run!.
// Results go to the EngineMailbox process by registered name (string target
// routing) — payload ["engine_result", runId, result].
window.__mnftEngine = {
  async run(code, id, sendApi) {
    try {
      await ensureWorker();
      pending.set(id, { send: sendApi });
      worker.postMessage({ type: "run", id, code });
      armWatchdog(id);
    } catch (err) {
      sendResult(sendApi, id, {
        ok: false,
        stage: "exec",
        error: String(err),
        elapsedMs: 0,
      });
    }
  },
};

const MAILBOX_TARGET = "mnft_engine_mailbox";

// ---------------------------------------------------------------------------
// transcript + stages
// ---------------------------------------------------------------------------
function addBubble(kind, text) {
  el.hint?.remove();
  const div = document.createElement("div");
  div.className = `bubble ${kind}`;
  div.textContent = text;
  el.transcript.appendChild(div);
  el.transcript.scrollTop = el.transcript.scrollHeight;
}

const STAGE_NAMES = ["llm", "exec", "turn"];

function stageReset() {
  for (const node of el.stages.querySelectorAll(".stage")) {
    node.dataset.active = "false";
    node.dataset.done = "false";
  }
}

function stageActive(name) {
  for (const node of el.stages.querySelectorAll(".stage")) {
    const i = STAGE_NAMES.indexOf(node.dataset.stage);
    const j = STAGE_NAMES.indexOf(name);
    if (i < j) {
      node.dataset.active = "false";
      node.dataset.done = "true";
    } else if (i === j) {
      node.dataset.active = "true";
      node.dataset.done = "false";
    }
  }
}

function stageDone() {
  for (const node of el.stages.querySelectorAll(".stage")) {
    node.dataset.active = "false";
    node.dataset.done = "true";
  }
}

function showStats(payload) {
  const mesh = payload.mesh;
  if (!mesh) {
    el.statTris.textContent = "";
    el.statBbox.textContent = "";
    el.statVol.textContent = "";
    el.statMs.textContent = "";
    return;
  }
  const bbox = mesh.bbox_mm;
  el.statTris.innerHTML = `<b>${Number(mesh.triangles).toLocaleString()}</b> tris`;
  el.statBbox.innerHTML =
    `bbox <b>${bbox.map((n) => Number(n).toFixed(1)).join(" × ")}</b> mm`;
  el.statVol.innerHTML = mesh.volume_mm3
    ? `vol <b>${(Number(mesh.volume_mm3) / 1000).toFixed(1)}</b> cm³`
    : "";
  el.statMs.innerHTML = `exec <b>${payload.meta?.exec_ms ?? "?"}</b> ms`;
}

function offerDownloads(payload) {
  el.downloads.replaceChildren();
  const modelId = payload.artifacts?.model_id;
  const artifact = modelId && window.__mnftArtifacts[modelId];
  if (!payload.ok || !artifact) return;

  for (const [name, bytes, type] of [
    [`model-${modelId}.stl`, artifact.stl, "application/octet-stream"],
    [`model-${modelId}.step`, artifact.step, "model/step"],
  ]) {
    const blob = new Blob([bytes], { type });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = name;
    a.textContent = `⬇ ${name} (${(blob.size / 1024).toFixed(1)} KB)`;
    el.downloads.appendChild(a);
    setTimeout(() => URL.revokeObjectURL(url), 60_000);
  }
}

// ---------------------------------------------------------------------------
// core events
// ---------------------------------------------------------------------------
let lastUserMessage = "";

function handleEvent(msg) {
  try {
    if (msg.type === "boot") {
      el.vm.textContent = `OTP ${msg.otp_release}`;
      el.vm.dataset.on = "true";
      el.engine.textContent = `engine ${msg.engine}`;
      el.journal.textContent = `journal ${msg.journal}`;
      setLlmChip(msg.llm);
      el.session.textContent = `session ${msg.session_id.slice(0, 8)}…`;
      el.session.title = msg.session_id;
      el.session.hidden = false;
      el.prompt.disabled = false;
      el.prompt.focus();
      return;
    }

    if (msg.type === "cad-event") {
      const { event, payload } = JSON.parse(msg.json);
      handleCadEvent(event, payload);
    }
  } catch (err) {
    console.error("[cad-event]", err);
  }
}

function handleCadEvent(event, payload) {
  switch (event) {
    case "turn_started":
      stageReset();
      stageActive("turn");
      addBubble("user", lastUserMessage);
      setTurnInFlight(true);
      break;
    case "llm_started":
      stageActive("llm");
      break;
    case "llm_done":
      stageActive("exec");
      break;
    case "exec_started":
      stageActive("exec");
      break;
    case "exec_done":
      stageActive("turn");
      break;
    case "turn_done":
      stageDone();
      addBubble("assistant", payload.reply || payload.error || "(no reply)");
      if (payload.ok) {
        showStats(payload);
        offerDownloads(payload);
        const art = window.__mnftArtifacts[payload.artifacts?.model_id];
        if (art?.bbox) showModel(art.positions, art.triangles, art.bbox);
      } else if (payload.error) {
        addBubble("error", payload.error_detail || payload.error);
      }
      setTurnInFlight(false);
      el.prompt.focus();
      break;
    case "turn_failed":
      stageDone();
      addBubble("error", payload.error || "turn failed");
      setTurnInFlight(false);
      el.prompt.focus();
      break;
  }
}

function setLlmChip(mode) {
  el.llm.textContent = `LLM ${mode}`;
  el.llm.dataset.on = mode === "byok" ? "true" : "false";
}

// ---------------------------------------------------------------------------
// boot + commands
// ---------------------------------------------------------------------------
async function kernelCall(args) {
  return await popcorn.tryCall("mnft_kernel", args);
}

const popcorn = await Popcorn.init({
  beam: { maxMemory: { mobile: "512M", desktop: "1G" } },
  onStdout: (t) => console.log("[beam]", t),
  onStderr: (t) => console.error("[beam]", t),
  onEvent: handleEvent,
});

// spike diagnostics: lets a console session reach the kernel bridge directly
window.__popcorn = popcorn;

el.run.addEventListener("click", submitPrompt);
el.prompt.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !el.run.disabled) submitPrompt();
});

async function submitPrompt() {
  const message = el.prompt.value.trim();
  if (!message || turnInFlight() || !workerReady) return;

  // Set before the call: turn_started (which echoes it) can beat the call
  // reply back to the page.
  lastUserMessage = message;
  el.prompt.value = "";

  let res;
  try {
    res = await kernelCall(["turn", el.session.title, message]);
  } catch (err) {
    el.prompt.value = message;
    lastUserMessage = "";
    addBubble("error", String(err));
    return;
  }
  if (!res.ok) {
    el.prompt.value = message;
    lastUserMessage = "";
    addBubble("error", res.error || "could not start the turn");
  }
}

// --- BYOK settings -----------------------------------------------------------
const STORAGE_KEY = "mnft.byok";

el.save.addEventListener("click", saveSettings);

async function saveSettings() {
  const cfg = {
    provider: el.provider.value,
    baseUrl: el.base.value.trim(),
    apiKey: el.key.value,
    model: el.model.value.trim(),
  };
  if (!cfg.apiKey || !cfg.model) {
    el.settingsStatus.textContent = "API key and model id are required";
    return;
  }
  const res = await applyLlmConfig(cfg);
  if (res.ok) {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(cfg));
    el.settingsStatus.textContent = "saved — real LLM active";
    setLlmChip("byok");
  } else {
    el.settingsStatus.textContent = `failed: ${res.error || "unknown error"}`;
  }
}

function applyLlmConfig(cfg) {
  return kernelCall(["llm_config", cfg.provider, cfg.baseUrl, cfg.apiKey, cfg.model]);
}

// Replay a saved config on load: keys never leave the browser, but a reload
// must not silently drop back to the scripted LLM.
const saved = localStorage.getItem(STORAGE_KEY);
if (saved) {
  try {
    const cfg = JSON.parse(saved);
    el.provider.value = cfg.provider ?? "openai";
    el.base.value = cfg.baseUrl ?? "";
    el.key.value = cfg.apiKey ?? "";
    el.model.value = cfg.model ?? "";
    const res = await applyLlmConfig(cfg);
    if (res.ok) {
      el.settingsStatus.textContent = "saved config restored";
      setLlmChip("byok");
    }
  } catch {
    localStorage.removeItem(STORAGE_KEY);
  }
}

resize();

// Continuous render: OrbitControls damping needs per-frame updates, and the
// panel can resize without a window resize event.
renderer.setAnimationLoop(() => {
  controls.update();
  renderer.render(scene, camera);
});

// Warm the kernel at page load (like cad_worker_web): spawn the worker now
// so the OCCT chip flips ready before the first turn, not during it.
ensureWorker().catch((err) => {
  el.occt.textContent = "OCCT failed";
  el.occt.dataset.err = "true";
  console.error("[worker]", err);
});

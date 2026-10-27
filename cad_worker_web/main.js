import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { SAMPLE_PART } from "./examples/sample_part.js";

// ---------------------------------------------------------------------------
// Worker + watchdog — the browser twin of cad_worker's rlimits + wall clock.
// A runaway model can only be stopped by killing the worker, so the page
// arms a 30 s watchdog per run and respawns a fresh sandbox on breach.
// ---------------------------------------------------------------------------
const WATCHDOG_MS = 30_000;

let worker = null;
let nextId = 1;
let runTimer = null;
let kernelReady = false;

const $ = (sel) => document.querySelector(sel);
const statusEl = $("#status");
const runBtn = $("#run");
const codeEl = $("#code");
const statsEl = $("#stats");
const errorEl = $("#error");
const downloadsEl = $("#downloads");

function setStatus(msg, busy = false) {
  statusEl.textContent = msg;
  statusEl.dataset.busy = busy ? "true" : "false";
  runBtn.disabled = busy || !kernelReady;
}

function spawnWorker() {
  worker = new Worker(new URL("./worker.js", import.meta.url), { type: "module" });
  worker.onmessage = (event) => {
    const data = event.data;
    if (data.type === "ready") {
      kernelReady = true;
      setStatus(`kernel ready (loaded in ${data.kernelMs} ms)`);
    } else if (data.type === "kernel-error") {
      setStatus("kernel failed to load");
      errorEl.textContent = data.error;
    } else if (pending.has(data.id)) {
      const resolve = pending.get(data.id);
      pending.delete(data.id);
      resolve(data);
    }
  };
  worker.onerror = (event) => {
    setStatus("worker crashed");
    errorEl.textContent = `worker error: ${event.message}`;
  };
  return worker;
}

const pending = new Map();
spawnWorker();

function terminateWorker() {
  if (runTimer) clearTimeout(runTimer);
  runTimer = null;
  worker?.terminate();
}

function runDialectCode(code) {
  return new Promise((resolve) => {
    const id = nextId++;
    pending.set(id, resolve);
    worker.postMessage({ type: "run", id, code });
    runTimer = setTimeout(() => {
      pending.delete(id);
      terminateWorker();
      spawnWorker();
      kernelReady = false;
      setStatus("watchdog: runaway model killed after 30 s, worker respawned");
      resolve({ ok: false, error: "watchdog: execution exceeded 30 s and was terminated" });
    }, WATCHDOG_MS);
  });
}

// ---------------------------------------------------------------------------
// three.js viewer
// ---------------------------------------------------------------------------
const canvasHost = $("#viewport");
const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setPixelRatio(window.devicePixelRatio);
canvasHost.appendChild(renderer.domElement);

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
  const w = canvasHost.clientWidth;
  const h = canvasHost.clientHeight;
  renderer.setSize(w, h);
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

  const size = new THREE.Vector3(bbox.max[0] - bbox.min[0], bbox.max[1] - bbox.min[1], bbox.max[2] - bbox.min[2]);
  const center = new THREE.Vector3((bbox.min[0] + bbox.max[0]) / 2, (bbox.min[1] + bbox.max[1]) / 2, (bbox.min[2] + bbox.max[2]) / 2);
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
// downloads
// ---------------------------------------------------------------------------
function offerDownload(name, blob) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.textContent = `⬇ ${name} (${(blob.size / 1024).toFixed(1)} KB)`;
  downloadsEl.appendChild(a);
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}

// ---------------------------------------------------------------------------
// wire up
// ---------------------------------------------------------------------------
codeEl.value = SAMPLE_PART;
downloadsEl.replaceChildren();

runBtn.addEventListener("click", async () => {
  errorEl.textContent = "";
  downloadsEl.replaceChildren();
  statsEl.textContent = "";
  setStatus("running dialect code…", true);
  const started = performance.now();

  const res = await runDialectCode(codeEl.value);
  if (runTimer) { clearTimeout(runTimer); runTimer = null; }

  if (!res.ok) {
    errorEl.textContent = res.error;
    if (!res.error.startsWith("watchdog")) setStatus("failed");
    return;
  }
  const v = res.stats.volumeMM3;
  statsEl.textContent =
    `picked "part" · ${res.stats.triangles.toLocaleString()} triangles · ` +
    (v ? `${(v / 1000).toFixed(1)} cm³ · ` : "") +
    `${res.elapsedMs} ms kernel, ${Math.round(performance.now() - started)} ms round-trip`;
  setStatus("done");
  showModel(res.positions, res.triangles, res.stats.bboxMM);
  offerDownload("model.stl", new Blob([res.stl], { type: "application/octet-stream" }));
  offerDownload("model.step", new Blob([res.step], { type: "model/step" }));
});

setStatus("loading OCCT kernel (~9 MB, cached after first visit)…", true);
resize();

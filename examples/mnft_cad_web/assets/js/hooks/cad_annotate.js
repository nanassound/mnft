// Annotation overlay for the CAD viewer: circle / free draw / text drawn on a
// 2D canvas layered above the WebGL canvas, plus "copy png" which composites
// renderer + overlay into a PNG on the system clipboard (paste target: the
// chat composer's photo-attach paste handler).
//
// Shapes live in client memory in normalized [0..1] coords and are cleared
// whenever a new model loads (viewer calls reset()).

const COLOR = "#dc2626"
const LINE_W = 2.5
const TEXT_FONT = "600 16px ui-sans-serif, system-ui, sans-serif"
const COPY_FEEDBACK_MS = 1500

function dpr() { return Math.min(window.devicePixelRatio || 1, 2) }

export function initAnnotations(viewer) {
  const wrap = viewer.wrap
  const overlay = document.createElement("canvas")
  overlay.style.cssText =
    "position:absolute;inset:0;width:100%;height:100%;pointer-events:none;touch-action:none"
  wrap.appendChild(overlay)
  const ctx = overlay.getContext("2d")

  let tool = null          // null | "pen" | "circle" | "text"
  let shapes = []
  let drawing = null       // in-progress shape
  let input = null         // active text input element

  const cssRect = () => overlay.getBoundingClientRect()

  // --- rendering ---------------------------------------------------------------

  function redraw() {
    const rect = cssRect()
    const w = Math.round(rect.width * dpr())
    const h = Math.round(rect.height * dpr())
    if (!rect.width || !rect.height) return
    if (overlay.width !== w) overlay.width = w
    if (overlay.height !== h) overlay.height = h
    ctx.setTransform(dpr(), 0, 0, dpr(), 0, 0)
    ctx.clearRect(0, 0, rect.width, rect.height)
    ctx.strokeStyle = COLOR
    ctx.fillStyle = COLOR
    ctx.lineWidth = LINE_W
    ctx.lineJoin = ctx.lineCap = "round"
    ctx.font = TEXT_FONT
    ctx.textBaseline = "top"
    const W = rect.width, H = rect.height
    for (const s of [...shapes, ...(drawing ? [drawing] : [])]) {
      if (s.kind === "pen") {
        if (s.pts.length < 2) continue
        ctx.beginPath()
        ctx.moveTo(s.pts[0][0] * W, s.pts[0][1] * H)
        for (const [x, y] of s.pts.slice(1)) ctx.lineTo(x * W, y * H)
        ctx.stroke()
      } else if (s.kind === "circle") {
        const x = Math.min(s.x1, s.x2) * W, y = Math.min(s.y1, s.y2) * H
        const rx = Math.abs(s.x2 - s.x1) * W / 2, ry = Math.abs(s.y2 - s.y1) * H / 2
        ctx.beginPath()
        ctx.ellipse(x + rx, y + ry, rx, ry, 0, 0, Math.PI * 2)
        ctx.stroke()
      } else if (s.kind === "text") {
        ctx.fillText(s.text, s.x * W, s.y * H)
      }
    }
  }

  // --- text input --------------------------------------------------------------

  function closeText(commit) {
    if (!input) return
    const value = input.value.trim()
    const at = { x: input._nx, y: input._ny }
    input.remove()
    input = null
    if (commit && value) {
      shapes.push({kind: "text", x: at.x, y: at.y, text: value})
      redraw()
    }
  }

  function openText(ev) {
    closeText(false)
    const rect = cssRect()
    const x = ev.clientX - rect.left, y = ev.clientY - rect.top
    input = document.createElement("input")
    input.id = "anno-text-input"
    input.style.cssText =
      "position:absolute;font:600 16px ui-sans-serif, system-ui, sans-serif;color:#dc2626;" +
      "background:rgba(255,255,255,0.92);border:1px solid #dc2626;border-radius:6px;" +
      "padding:2px 6px;outline:none;z-index:2"
    input.style.left = `${x}px`
    input.style.top = `${y}px`
    input._nx = x / rect.width
    input._ny = y / rect.height
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") { e.preventDefault(); closeText(true) }
      if (e.key === "Escape") { e.preventDefault(); closeText(false) }
    })
    input.addEventListener("blur", () => closeText(true))
    input.addEventListener("pointerdown", (e) => e.stopPropagation())
    wrap.appendChild(input)
    input.focus()
  }

  // --- pointer drawing -----------------------------------------------------------

  function norm(ev) {
    const rect = cssRect()
    return [(ev.clientX - rect.left) / rect.width, (ev.clientY - rect.top) / rect.height]
  }

  function onDown(ev) {
    if (!tool) return
    ev.preventDefault()
    overlay.setPointerCapture(ev.pointerId)
    if (tool === "text") { openText(ev); return }
    if (tool === "pen") drawing = {kind: "pen", pts: [norm(ev)]}
    if (tool === "circle") { const [x, y] = norm(ev); drawing = {kind: "circle", x1: x, y1: y, x2: x, y2: y} }
  }

  function onMove(ev) {
    if (!drawing) return
    ev.preventDefault()
    const rect = cssRect()
    if (drawing.kind === "pen") {
      const p = norm(ev)
      const last = drawing.pts[drawing.pts.length - 1]
      const dx = (p[0] - last[0]) * rect.width, dy = (p[1] - last[1]) * rect.height
      if (Math.hypot(dx, dy) >= 1.5) drawing.pts.push(p)
    } else if (drawing.kind === "circle") {
      const [x, y] = norm(ev)
      drawing.x2 = x; drawing.y2 = y
    }
    redraw()
  }

  function onUp() {
    if (!drawing) return
    const s = drawing
    drawing = null
    const rect = cssRect()
    const keep =
      (s.kind === "pen" && s.pts.length >= 2) ||
      (s.kind === "circle" &&
        Math.abs(s.x2 - s.x1) * rect.width >= 3 && Math.abs(s.y2 - s.y1) * rect.height >= 3)
    if (keep) shapes.push(s)
    redraw()
  }

  function onCancel() {
    drawing = null
    redraw()
  }

  // --- toolbar wiring ------------------------------------------------------------

  const toolButtons = () => Array.from(document.querySelectorAll("[data-anno]"))

  function setTool(next) {
    tool = tool === next ? null : next
    for (const b of toolButtons()) b.setAttribute("aria-pressed", String(b.dataset.anno === tool))
    overlay.style.pointerEvents = tool ? "auto" : "none"
    viewer.controls.enabled = !tool
    if (!tool) closeText(false)
  }

  function setCopyLabel(text) {
    const btn = document.getElementById("anno-copy")
    if (!btn) return
    const original = "copy png"
    btn.textContent = text
    setTimeout(() => { if (btn.textContent === text) btn.textContent = original }, COPY_FEEDBACK_MS)
  }

  async function copyImage() {
    if (!viewer.mesh) return
    const src = viewer.renderer.domElement
    viewer.renderer.render(viewer.scene, viewer.camera) // fresh frame → buffer readable
    const out = document.createElement("canvas")
    out.width = src.width; out.height = src.height
    const c = out.getContext("2d")
    c.drawImage(src, 0, 0)
    c.drawImage(overlay, 0, 0, out.width, out.height)
    try {
      // Promise-valued ClipboardItem keeps Safari happy about the user gesture.
      await navigator.clipboard.write([
        new ClipboardItem({"image/png": new Promise((res) => out.toBlob(res, "image/png"))}),
      ])
      setCopyLabel("copied")
    } catch {
      const a = document.createElement("a")
      a.href = out.toDataURL("image/png")
      a.download = "annotated-model.png"
      a.click()
      setCopyLabel("downloaded")
    }
  }

  function onClick(e) {
    const toolBtn = e.target.closest("[data-anno]")
    if (toolBtn) { setTool(toolBtn.dataset.anno); return }
    const action = e.target.closest("[data-anno-action]")
    if (!action) return
    if (action.dataset.annoAction === "undo") { shapes.pop(); redraw() }
    if (action.dataset.annoAction === "clear") { shapes = []; redraw() }
    if (action.dataset.annoAction === "copy") copyImage()
  }

  document.addEventListener("click", onClick)
  overlay.addEventListener("pointerdown", onDown)
  overlay.addEventListener("pointermove", onMove)
  overlay.addEventListener("pointerup", onUp)
  overlay.addEventListener("pointercancel", onCancel)

  // --- lifecycle API ---------------------------------------------------------------

  return {
    redraw,

    // new model loaded: drop tool state and every annotation
    reset() {
      tool = null
      shapes = []
      drawing = null
      closeText(false)
      for (const b of toolButtons()) b.setAttribute("aria-pressed", "false")
      overlay.style.pointerEvents = "none"
      viewer.controls.enabled = true
      redraw()
    },

    destroy() {
      document.removeEventListener("click", onClick)
      closeText(false)
      overlay.remove()
      viewer.controls.enabled = true
    },
  }
}

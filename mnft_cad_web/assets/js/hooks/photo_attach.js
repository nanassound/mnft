// Composer hook: photo attach (EXIF-safe downscale to JPEG), paste / drop,
// suggestion chips, and the "send" push. Photos stay in browser memory and
// are sent only with the turn; the server keeps only a small `thumb` data
// URL per photo, shown in the chat transcript.
const MAX_ATTACHMENTS = 2
const PHOTO_MAX_EDGE = 1280
const PHOTO_JPEG_QUALITY = 0.82
const THUMB_MAX_EDGE = 256
const THUMB_JPEG_QUALITY = 0.7

async function loadIntoCanvas(dataUrl, maxEdge, quality) {
  const img = new Image()
  await new Promise((resolve, reject) => { img.onload = resolve; img.onerror = () => reject(new Error("bad image")); img.src = dataUrl })
  const scale = Math.min(1, maxEdge / Math.max(img.naturalWidth, img.naturalHeight))
  const canvas = document.createElement("canvas")
  canvas.width = Math.max(1, Math.round(img.naturalWidth * scale))
  canvas.height = Math.max(1, Math.round(img.naturalHeight * scale))
  canvas.getContext("2d").drawImage(img, 0, 0, canvas.width, canvas.height)
  return canvas.toDataURL("image/jpeg", quality)
}

async function thumbFromDataUrl(dataUrl) {
  try { return await loadIntoCanvas(dataUrl, THUMB_MAX_EDGE, THUMB_JPEG_QUALITY) } catch { return null }
}

async function fileToJpegDataUrl(file) {
  let bitmap = null, img = null, url = null, w, h, draw
  if (window.createImageBitmap) {
    try { bitmap = await createImageBitmap(file, {imageOrientation: "from-image"}) } catch { /* fall back */ }
  }
  if (bitmap) {
    w = bitmap.width; h = bitmap.height
    draw = (ctx) => ctx.drawImage(bitmap, 0, 0, w, h)
  } else {
    url = URL.createObjectURL(file)
    img = new Image()
    await new Promise((resolve, reject) => {
      img.onload = resolve
      img.onerror = () => reject(new Error("could not decode image"))
      img.src = url
    })
    w = img.naturalWidth; h = img.naturalHeight
    draw = (ctx) => ctx.drawImage(img, 0, 0, w, h)
  }
  const scale = Math.min(1, PHOTO_MAX_EDGE / Math.max(w, h))
  w = Math.max(1, Math.round(w * scale)); h = Math.max(1, Math.round(h * scale))
  const canvas = document.createElement("canvas")
  canvas.width = w; canvas.height = h
  draw(canvas.getContext("2d"))
  const dataUrl = canvas.toDataURL("image/jpeg", PHOTO_JPEG_QUALITY)
  if (bitmap) bitmap.close()
  if (url) URL.revokeObjectURL(url)
  return dataUrl
}

export const PhotoAttach = {
  mounted() {
    this.attachments = []
    this.form = this.el.querySelector("#chat-form")
    this.input = this.el.querySelector("#chat-input")
    this.chips = this.el.querySelector("#attachments")
    this.file = this.el.querySelector("[data-file]")

    this.el.addEventListener("click", (e) => {
      if (e.target.closest("[data-attach]")) this.file.click()
      const chip = e.target.closest("[data-prompt]")
      if (chip) { this.input.value = chip.dataset.prompt; this.input.focus() }
    })

    this.file.addEventListener("change", async () => {
      await this.attach([...this.file.files])
      this.file.value = ""
    })

    this.form.addEventListener("submit", async (e) => {
      e.preventDefault()
      const message = this.input.value.trim()
      if (!message || this.input.disabled) return
      const photos = []
      for (const a of this.attachments) {
        photos.push({data_url: a.dataUrl, label: "reference", thumb: await thumbFromDataUrl(a.dataUrl)})
      }
      let current = null
      if (window.cadSnapshot) {
        // Always keep the agent's mesh context, but never append a "current"
        // render photo — a pasted annotated view already shows the model, so
        // the extra image would just duplicate it in the transcript.
        const snap = window.cadSnapshot()
        if (snap) current = snap.mesh
      }
      this.pushEvent("send", {message, photos, current})
      this.input.value = ""
      this.attachments = []
      this.render()
    })

    this.onPaste = async (e) => {
      const files = [...(e.clipboardData?.items || [])]
        .filter((i) => i.kind === "file" && i.type.startsWith("image/"))
        .map((i) => i.getAsFile()).filter(Boolean)
      if (files.length) { e.preventDefault(); await this.attach(files) }
    }
    document.addEventListener("paste", this.onPaste)

    this.onDragOver = (e) => e.preventDefault()
    this.onDrop = async (e) => {
      const files = [...(e.dataTransfer?.files || [])].filter((f) => f.type.startsWith("image/"))
      if (files.length) { e.preventDefault(); await this.attach(files) }
    }
    document.addEventListener("dragover", this.onDragOver)
    document.addEventListener("drop", this.onDrop)
  },

  destroyed() {
    document.removeEventListener("paste", this.onPaste)
    document.removeEventListener("dragover", this.onDragOver)
    document.removeEventListener("drop", this.onDrop)
  },

  async attach(files) {
    for (const f of files) {
      if (this.attachments.length >= MAX_ATTACHMENTS) break
      try {
        this.attachments.push({dataUrl: await fileToJpegDataUrl(f), name: f.name})
      } catch (err) {
        alert("Could not read that photo: " + err.message)
      }
    }
    this.render()
  },

  render() {
    this.chips.replaceChildren()
    this.attachments.forEach((a, i) => {
      const chip = document.createElement("span")
      chip.className = "relative inline-block"
      const thumb = document.createElement("img")
      thumb.src = a.dataUrl; thumb.alt = a.name || "attached photo"
      thumb.className = "size-12 rounded-lg border border-zinc-200 object-cover"
      const rm = document.createElement("button")
      rm.type = "button"; rm.textContent = "✕"; rm.setAttribute("aria-label", "remove photo")
      rm.className = "absolute -right-1.5 -top-1.5 grid size-5 place-items-center rounded-full bg-zinc-900 text-[10px] text-white"
      rm.addEventListener("click", () => { this.attachments.splice(i, 1); this.render() })
      chip.append(thumb, rm)
      this.chips.appendChild(chip)
    })
  },
}

// Keeps the transcript scrolled to the newest message.
export const Transcript = {
  mounted() { this.scroll() },
  updated() { this.scroll() },
  scroll() { this.el.scrollTop = this.el.scrollHeight },
}

// Three.js viewer hook (port of the PoC's initViewer/showModel/snapshot).
// The wrapper element carries data-model (JSON); the canvas lives in an inner
// phx-update="ignore" container so LiveView diffs never touch it.
import * as THREE from "three"
import {OrbitControls} from "../../vendor/three/OrbitControls.js"
import {STLLoader} from "../../vendor/three/STLLoader.js"
import {initAnnotations} from "./cad_annotate.js"

export const CadViewer = {
  mounted() {
    this.edgesOn = true
    this.mesh = this.edges = this.grid = null
    this.lastId = null
    this.wrap = this.el.querySelector("[id$='canvas-wrap']") || this.el
    this.canvas = document.createElement("canvas")
    this.canvas.style.cssText = "width:100%;height:100%;display:block"
    this.wrap.appendChild(this.canvas)

    this.renderer = new THREE.WebGLRenderer({canvas: this.canvas, antialias: true})
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2))
    this.scene = new THREE.Scene()
    this.scene.background = new THREE.Color(0xeef0f3)
    this.camera = new THREE.PerspectiveCamera(40, 1, 0.1, 1e6)
    this.controls = new OrbitControls(this.camera, this.canvas)
    this.controls.enableDamping = true
    this.controls.dampingFactor = 0.08
    if (this.el.dataset.autorotate) { this.controls.autoRotate = true; this.controls.autoRotateSpeed = 1.2 }
    this.scene.add(new THREE.HemisphereLight(0xffffff, 0x9aa0a6, 1.15))
    const key = new THREE.DirectionalLight(0xffffff, 1.5); key.position.set(1, 2, 1.2); this.scene.add(key)
    const fill = new THREE.DirectionalLight(0xffffff, 0.5); fill.position.set(-1.5, 0.8, -1); this.scene.add(fill)

    this.ro = new ResizeObserver(() => this.resize())
    this.ro.observe(this.el)
    this.renderer.setAnimationLoop(() => { this.controls.update(); this.renderer.render(this.scene, this.camera) })

    this.onEdges = (e) => {
      if (!e.target.closest("[data-edges]")) return
      const btn = e.target.closest("[data-edges]")
      this.edgesOn = !this.edgesOn
      if (this.edges) this.edges.visible = this.edgesOn
      btn.setAttribute("aria-pressed", String(this.edgesOn))
    }
    document.addEventListener("click", this.onEdges)

    this.anno = initAnnotations(this)

    // used by the photo hook for "current model" renders
    window.cadSnapshot = (w = 900, h = 675) => this.snapshot(w, h)

    this.resize()
    this.sync()
  },

  updated() { this.sync() },

  destroyed() {
    document.removeEventListener("click", this.onEdges)
    this.anno && this.anno.destroy()
    this.ro && this.ro.disconnect()
    this.renderer && (this.renderer.setAnimationLoop(null), this.renderer.dispose())
    if (window.cadSnapshot) delete window.cadSnapshot
  },

  sync() {
    const raw = this.el.dataset.model
    if (!raw) return
    const data = JSON.parse(raw)
    if (data.id === this.lastId) return
    this.lastId = data.id
    this.anno && this.anno.reset()
    this.lastMesh = data.mesh
    new STLLoader().load(data.stl, (geom) => this.show(geom))
  },

  show(geom) {
    const {scene, camera, controls} = this
    if (this.mesh) { scene.remove(this.mesh); this.mesh.geometry.dispose(); this.mesh.material.dispose() }
    if (this.edges) { scene.remove(this.edges); this.edges.geometry.dispose() }
    if (this.grid) { scene.remove(this.grid); this.grid.geometry.dispose(); this.grid.material.dispose() }

    // build123d is Z-up, base on Z=0; three.js is Y-up
    geom.computeBoundingBox()
    let bb = geom.boundingBox
    const c = new THREE.Vector3(); bb.getCenter(c)
    geom.translate(-c.x, -c.y, -bb.min.z)
    geom.rotateX(-Math.PI / 2)
    geom.computeBoundingBox()
    bb = geom.boundingBox
    const size = new THREE.Vector3(); bb.getSize(size)
    const maxDim = Math.max(size.x, size.y, size.z) || 1

    this.mesh = new THREE.Mesh(geom, new THREE.MeshStandardMaterial({color: 0x98a1ab, metalness: 0.15, roughness: 0.55}))
    scene.add(this.mesh)
    this.edges = new THREE.LineSegments(new THREE.EdgesGeometry(geom, 25), new THREE.LineBasicMaterial({color: 0x41454d}))
    this.edges.visible = this.edgesOn
    scene.add(this.edges)
    const gridSize = Math.ceil((maxDim * 2.4) / 10) * 10
    this.grid = new THREE.GridHelper(gridSize, Math.max(10, Math.round(gridSize / 10)), 0xb7bcc2, 0xd9dcdf)
    scene.add(this.grid)

    this.resize()
    const halfFov = (camera.fov * Math.PI) / 360
    const vFit = (maxDim / 2) / Math.tan(halfFov)
    const hFit = (maxDim / 2) / (Math.tan(halfFov) * (camera.aspect || 1))
    const dist = Math.max(vFit, hFit) * 1.5
    camera.position.set(dist * 0.8, size.y / 2 + dist * 0.55, dist * 0.8)
    camera.near = maxDim / 100
    camera.far = dist * 20
    controls.target.set(0, size.y / 2, 0)
    controls.update()
  },

  resize() {
    const w = this.el.clientWidth, h = this.el.clientHeight
    if (!w || !h) return
    this.renderer.setSize(w, h, false)
    this.camera.aspect = w / h
    this.camera.updateProjectionMatrix()
    this.anno && this.anno.redraw()
  },

  snapshot(width, height) {
    if (!this.mesh || !this.lastMesh) return null
    const {renderer, scene, camera} = this
    const pw = renderer.domElement.width, ph = renderer.domElement.height
    const pa = camera.aspect || 1
    renderer.setSize(width, height, false)
    camera.aspect = width / height
    camera.updateProjectionMatrix()
    renderer.render(scene, camera)
    const dataUrl = renderer.domElement.toDataURL("image/jpeg", 0.85)
    camera.aspect = pa
    camera.updateProjectionMatrix()
    if (pw > 0 && ph > 0) renderer.setSize(pw, ph, false)
    return {dataUrl, mesh: this.lastMesh}
  },
}

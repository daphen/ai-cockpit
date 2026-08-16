import QtQuick
import QsLib

// "Thinking" orb — a slowly revolving wireframe network sphere: an orthographic
// projection of points on a unit sphere, rotated around Y each frame (real 3D
// globe spin). The feed-update debounce keeps the main thread free enough that
// this Canvas animation stays smooth during streaming.
Item {
  id: orb
  property bool running: true
  property color glow: Theme.fg
  implicitWidth: 26
  implicitHeight: 26
  visible: running

  // Node count scales with size. At roster size the 26-node mesh collapsed into a dark
  // blob: R is ~5px there, the edge threshold spans almost the whole disc, so all ~325
  // pairs drew a line. But 0.55 overshot the other way — 8 nodes at 14px read as thin
  // and scattered. 0.93 puts the roster orb at 13, which holds together as a mesh
  // (chosen against a true-size side-by-side; a scaled preview magnifies the Canvas
  // raster and tells you nothing).
  property int nodes: width >= 22 ? 26 : Math.max(6, Math.round(width * 0.93))

  property var _pts: []
  property real rot: 0

  Component.onCompleted: _build()
  onNodesChanged: _build()
  function _build() {
    // Guard: onNodesChanged can fire while the component is still being created (setting
    // `nodes` explicitly at a use site triggers it), and the JS globals are not reliably
    // there yet — the harness caught "Math is undefined" from exactly that path.
    if (typeof Math === "undefined" || orb.nodes === undefined) return
    var n = Math.max(4, orb.nodes), pts = [], off = 2 / n, inc = Math.PI * (3 - Math.sqrt(5))  // fibonacci sphere
    for (var i = 0; i < n; i++) {
      var y = i * off - 1 + off / 2
      var r = Math.sqrt(Math.max(0, 1 - y * y))
      var phi = i * inc
      pts.push([Math.cos(phi) * r, y, Math.sin(phi) * r])
    }
    _pts = pts
    canvas.requestPaint()
  }

  // Rotation is a WALL-CLOCK phase, not animation state: a stored-from-zero
  // NumberAnimation restarted whenever `running` flapped (pi's status flips
  // between tool cycles) or the delegate was recreated — the orb visibly
  // snapped back to its start pose. A clock phase cannot reset, and every orb
  // on screen spins in unison for free.
  FrameAnimation {
    running: orb.running
    onTriggered: orb.rot = (Date.now() % 7000) / 7000 * 2 * Math.PI
  }
  onRotChanged: canvas.requestPaint()
  onGlowChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    // Paint on the render thread: under streaming load the cooperative main-thread
    // repaints starved and the orb visibly stuttered/blanked.
    renderStrategy: Canvas.Threaded
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var w = width, h = height, cx = w / 2, cy = h / 2
      // Largest sphere that still fits its own dots: a node sits at distance R and its
      // dot reaches R*0.20 past that, so the inset has to be that dot radius, not a
      // fixed 1.5px. At small sizes the flat inset was most of the difference — a 16px
      // box drew a ~13px sphere, so making the box bigger barely showed.
      // Badge chrome: an animated gradient disc behind the mesh, ringed in white.
      // The gradient's axis rides the same wall-clock phase as the sphere, so the
      // light appears to orbit with it. The mesh insets inside the ring.
      var ring = Math.max(1.5, Math.min(w, h) * 0.09)
      var discR = Math.min(w, h) / 2 - ring / 2 - 1   // 1px in from the item edge (AA headroom)
      var g0 = orb.glow
      // Lit-sphere shading: a radial gradient whose HIGHLIGHT orbits with the
      // phase — offset bright core → saturated glow mid → near-black rim. Big
      // luminance range is what makes it read as a gradient at 20px.
      // The highlight's own full-period clock: any (t%P)/P*2pi phase is continuous
      // at the wrap — rot*0.7 wrapped mid-angle and snapped every 7 seconds.
      var gphase = (Date.now() % 11000) / 11000 * 2 * Math.PI
      var gx = Math.cos(gphase), gy = Math.sin(gphase)
      var hx = cx + gx * discR * 0.45, hy = cy + gy * discR * 0.45
      var grad = ctx.createRadialGradient(hx, hy, discR * 0.05, cx, cy, discR * 1.25)
      grad.addColorStop(0.0, Qt.rgba(Math.min(1, g0.r * 0.6 + 0.5), Math.min(1, g0.g * 0.6 + 0.5), Math.min(1, g0.b * 0.6 + 0.5), 1))
      grad.addColorStop(0.35, Qt.rgba(g0.r, g0.g, g0.b, 1))
      grad.addColorStop(1.0, Qt.rgba(g0.r * 0.12, g0.g * 0.12, g0.b * 0.20, 1))
      ctx.beginPath(); ctx.arc(cx, cy, discR, 0, 2 * Math.PI)
      ctx.fillStyle = grad; ctx.fill()
      ctx.lineWidth = ring
      // Ring ink follows the theme: white on dark ground, near-black on light —
      // a white ring on a light surface is an invisible border.
      ctx.strokeStyle = Theme.mode === "light" ? "#1F1F1F" : "#FFFFFF"
      ctx.beginPath(); ctx.arc(cx, cy, discR, 0, 2 * Math.PI); ctx.stroke()

      var R = (Math.min(w, h) / 2 - ring * 1.6) / 1.2
      var ca = Math.cos(orb.rot), sa = Math.sin(orb.rot)
      var tilt = 0.45, ct = Math.cos(tilt), st = Math.sin(tilt)
      var proj = []
      for (var i = 0; i < orb._pts.length; i++) {
        var p = orb._pts[i]
        var x = p[0] * ca - p[2] * sa
        var z = p[0] * sa + p[2] * ca
        var y = p[1] * ct - z * st
        var zz = p[1] * st + z * ct               // depth, -1 (back) … 1 (front)
        proj.push([cx + x * R, cy - y * R, zz])
      }
      var g = orb.glow
      for (var e = 0; e < orb._pts.length; e++)
        for (var f = e + 1; f < orb._pts.length; f++) {
          var dx = proj[e][0] - proj[f][0], dy = proj[e][1] - proj[f][1]
          // Sparser meshes need a wider reach to connect at all; dense ones need a
          // tighter one or every pair links.
          var reach = R * (orb._pts.length > 16 ? 0.72 : 0.95)
          if (dx * dx + dy * dy < reach * reach) {
            var d = (proj[e][2] + proj[f][2]) / 2
            ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.14 + (d + 1) / 2 * 0.38)
            ctx.lineWidth = Math.max(0.5, R * 0.07)
            ctx.beginPath(); ctx.moveTo(proj[e][0], proj[e][1]); ctx.lineTo(proj[f][0], proj[f][1]); ctx.stroke()
          }
        }
      for (var j = 0; j < proj.length; j++) {
        var dd = proj[j][2]
        ctx.fillStyle = Qt.rgba(1, 1, 1, 0.45 + (dd + 1) / 2 * 0.55)
        // Radius as a FRACTION of R, not absolute px — 2px dots on a 5px radius are
        // what made the small orb read as filled.
        var rr = R * (0.10 + (dd + 1) / 2 * 0.10)
        ctx.beginPath(); ctx.arc(proj[j][0], proj[j][1], rr, 0, 2 * Math.PI); ctx.fill()
      }
    }
  }
}

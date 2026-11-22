import QtQuick

// A session switch, one phase at a time:
//   out    — the old cards fade out while the new transcript is fetched
//   wait   — faded out, waiting for that transcript (bounded by waitCapMs)
//   settle — the new cards are swapped in, hidden, while they build and first draw
//   in     — they fade in
//   idle   — nothing in flight
// A new request in any phase restarts from the current opacity, so rapid switching
// never shows a session other than the latest one.
QtObject {
  id: sw

  property var agentd: null
  // Faded on the render thread, so building the new cards cannot stall the fade.
  property Item target
  // The rail has built enough cards to fill the screen.
  property bool covered: true
  property string shown: ""
  property string phase: "idle"
  readonly property bool busy: phase !== "idle"

  readonly property int outMs: 90
  readonly property int inMs: 150
  readonly property int waitCapMs: 600
  readonly property int settleCapMs: 250
  // Not 0: an invisible item is never drawn, so the new cards' first draw would land in the fade-in.
  readonly property real hidden: 0.002

  signal swap(string sid)

  property string _want: ""
  property bool _ready: true
  property int _calm: 0
  property real _since: 0

  function request(sid) {
    _want = sid
    // Saved cards are current unless select() is fetching; then wait (capped) so it never lands after the fade-in.
    _ready = !(agentd && sid && agentd.select(sid))
    if (!shown || !sid) { _stopAll(); target.opacity = 1; phase = "idle"; _doSwap(); return }
    if (_ready) _cap.stop(); else _cap.restart()
    phase = "out"
    _settle.running = false
    _fadeTo(hidden, Math.round(outMs * _current()))
  }
  function entriesLoaded(sid) {
    if (sid !== _want || _ready) return
    _ready = true
    _cap.stop()
    if (phase === "wait") _enterSettle()
  }

  function _stopAll() { _fade.stop(); _cap.stop(); _settle.running = false }
  property real _from: 1
  property real _to: 1
  property real _t0: 0
  // The animator reports the target's opacity only once it finishes; mid-fade, follow its curve.
  function _current() {
    if (!_fade.running) return target.opacity
    var t = Math.min(1, (Date.now() - _t0) / _fade.duration)
    return _from + (_to - _from) * (1 - Math.pow(1 - t, 3))
  }
  function _fadeTo(v, ms) {
    var cur = _current()
    _fade.stop()
    if (Math.abs(cur - v) < 0.001 || ms <= 0) { target.opacity = v; _arrived(); return }
    _from = cur; _to = v; _t0 = Date.now()
    _fade.from = cur; _fade.to = v; _fade.duration = ms
    _fade.start()
  }
  function _arrived() {
    if (phase === "out") { phase = "wait"; if (_ready) _enterSettle() }
    else if (phase === "in") phase = "idle"
  }
  function _enterSettle() {
    phase = "settle"
    _doSwap()
    _calm = 0
    _since = Date.now()
    _settle.running = true
  }
  function _doSwap() {
    if (shown !== _want) { shown = _want; swap(_want) }
  }

  readonly property OpacityAnimator _fade: OpacityAnimator {
    target: sw.target; easing.type: Easing.OutCubic
    onFinished: sw._arrived()
  }
  readonly property Timer _cap: Timer {
    interval: sw.waitCapMs
    onTriggered: { sw._ready = true; if (sw.phase === "wait") sw._enterSettle() }
  }
  // How many long frames the new cards take varies by session; two on-time frames in a
  // row with the screen covered means they are built and drawn.
  readonly property FrameAnimation _settle: FrameAnimation {
    running: false
    onTriggered: {
      sw._calm = frameTime < 0.025 ? sw._calm + 1 : 0
      if ((sw._calm < 2 || !sw.covered) && Date.now() - sw._since < sw.settleCapMs) return
      running = false
      sw.phase = "in"
      sw._fadeTo(1, sw.inMs)
    }
  }
}

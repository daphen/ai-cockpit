import QtQuick

// The ONE owner of the chat viewport.
//
// Six things used to move the feed on their own cadence — a 250ms follow timer, a
// first-load settle burst, onCountChanged, the wheel handler, drag/flick handlers and
// cursor moves — while four booleans (pinBottom, _wantBottom, _sendPin, scrollGuarded)
// tried to arbitrate between them. They oscillated: the follow timer's programmatic
// scroll tripped the handlers that were supposed to detect USER scrolling, which
// unpinned follow, which re-pinned on the next tick, and scrolling wedged.
//
// So: callers only report EVENTS, this object owns the mode, and it is the only thing
// that calls positionViewAt*. One writer, so there is nothing left to fight over.
QtObject {
  id: sm

  property var view: null          // the feed ListView
  property bool streaming: false   // selected session is mid-turn
  property bool chatVisible: true   // the chat view is the one on screen

  //   follow — pinned to the newest content, the default
  //   free   — the user scrolled away and is reading; nothing auto-moves
  //   seek   — a one-shot programmatic move is in flight (session switch / send)
  readonly property string mode: _mode
  readonly property bool following: _mode === "follow"

  // The cursor should land on the last row. `force` distinguishes an explicit jump (a
  // session switch or a send, which may pull the cursor out of the roster) from merely
  // following growth, which must never yank a cursor that is browsing the roster.
  signal wantCursorAtEnd(bool force)

  property string _mode: "follow"
  property bool _pendingEnd: false
  property bool _settleWanted: false

  // A user gesture wins outright for this long: while it runs, nothing auto-positions.
  // Without it the follow timer fought the wheel and the feed felt locked.
  readonly property bool _guarded: _guard.running
  readonly property Timer _guard: Timer { interval: 700 }

  // Follow the bottom via the SUPPORTED api on a bounded cadence. Writing contentY
  // directly fights ListView's layout bookkeeping while the streaming card resizes,
  // and positioning synchronously on contentHeightChanged re-triggers delegate
  // incubation into a 100%-CPU refill loop.
  readonly property Timer _followTimer: Timer {
    interval: 250; repeat: true
    running: sm.chatVisible && sm.streaming && sm.following && !sm._guarded
    onTriggered: sm._toEnd()
  }

  // On a first load the delegates aren't realized, so contentHeight is an estimate and
  // one positionViewAtEnd lands mid-feed. Re-pin over ~540ms until geometry settles.
  readonly property Timer _settle: Timer {
    interval: 60; repeat: true
    property int n: 0
    onTriggered: {
      if (sm.chatVisible && sm.following) sm._toEnd()
      n++
      if (n >= 9) { running = false; n = 0 }
    }
  }

  // How close to the bottom counts as "back at the live edge". 8px meant you had to land
  // on the exact last pixel to resume following, so scrolling down to catch up left the
  // feed detached and reading as if follow were broken.
  readonly property int bottomSlack: 48

  function _atBottom() {
    if (!view) return true
    // Do NOT trust atYEnd: with async delegates contentHeight is an estimate and it
    // reports true mid-feed, which used to leave follow armed while the user was reading.
    return view.contentY >= view.contentHeight - view.height - bottomSlack
  }

  function _toEnd() {
    if (view && !_guarded) view.positionViewAtEnd()
  }

  // ── events ────────────────────────────────────────────────────────────────────

  // The wheel: ScrollFeel writes contentY directly, so it sets neither `dragging` nor
  // `flicking` and its signal is the only reliable "the user scrolled".
  function userScrolled(up) {
    _guard.restart()
    _mode = (up || !_atBottom()) ? "free" : "follow"
  }

  // Drag/flick ended. These two are user-gesture-only, unlike movementStarted/Ended,
  // which Flickable also emits for programmatic contentY changes.
  function gestureStarted() { _guard.restart(); _mode = "free" }
  function gestureEnded() {
    _guard.restart()
    _mode = _atBottom() ? "follow" : "free"
  }

  // A row was added or removed. While following, the cursor moves with the bottom:
  // leaving it behind put the highlight on an old row while the viewport showed the
  // newest one, so `k` then jumped from a position the user could no longer see.
  function contentChanged() {
    if (!chatVisible || !following || _guarded) return
    wantCursorAtEnd(false)
    Qt.callLater(_toEnd)
  }

  // The feed model finished reconciling (streaming tick, or a switch's first load).
  function synced() {
    if (!chatVisible) return
    if (_pendingEnd) {
      _pendingEnd = false
      _mode = "follow"
      wantCursorAtEnd(true)
      _toEnd()
      if (_settleWanted) { _settleWanted = false; _settle.n = 0; _settle.restart() }
      return
    }
    if (following) _toEnd()
  }

  // Jump to the newest content. `settle` re-pins through async delegate sizing — true
  // for a session switch (rows unsized), false for a send (rows already sized, where
  // the extra re-pins were visible as a flicker).
  function toEnd(settle) {
    _mode = "seek"
    _pendingEnd = true
    _settleWanted = settle === true
  }

  // The cursor moved to `idx`. Landing on the last row means "follow the stream"; any
  // other row is a deliberate move away from the bottom, so reveal it ONCE — as a
  // standing constraint (ApplyRange) it re-ran on every model change and yanked the view.
  function cursorMoved(idx, isLast) {
    if (!chatVisible || !view) return
    if (isLast) {
      _mode = "follow"
      Qt.callLater(_toEnd)
      return
    }
    _mode = "free"
    if (streaming) Qt.callLater(function () { if (sm.view) sm.view.positionViewAtIndex(idx, ListView.Contain) })
  }
}

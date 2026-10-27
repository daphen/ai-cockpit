import QtQuick

// The ONE owner of the chat viewport — the slqs/dsqrd MessageList pattern, ported.
//
// The previous version was a state machine with five timers (follow poll, settle burst,
// guard window, repin, seek handshake) all compensating for ONE root cause: the feed was
// virtualized, so contentHeight was an ESTIMATE and every positionViewAtEnd landed on a
// guess — short by a stable 332px at the row cap, 1.5 cards behind on a fast stream. The
// feed is capped at 60 rows (feedCap), the same scale as a slack channel, so the fix is
// the family's: realize everything (feedView sets cacheBuffer huge), heights become
// exact, and following is a bool plus one exact assignment. No polling, no arbitration:
// the writers are all event-driven, so there is nothing left to fight over.
QtObject {
  id: sm

  property var view: null          // the feed ListView
  property bool chatVisible: true  // the chat view is the one on screen

  //   follow — stuck to the newest content, the default
  //   free   — the user scrolled away and is reading; nothing auto-moves
  readonly property string mode: _stick ? "follow" : "free"
  readonly property bool following: _stick

  // The cursor should land on the last row. `force` distinguishes an explicit jump (a
  // session switch or a send, which may pull the cursor out of the roster) from merely
  // following growth, which must never yank a cursor that is browsing the roster.
  signal wantCursorAtEnd(bool force)

  property bool _stick: true
  // A switch/send wants the CURSOR at the end too, but the rows may not exist yet (the
  // transcript loads async). Consumed by the first synced() that actually has rows —
  // spending it earlier was how the cursor once landed on a roster row.
  property bool _pendingCursor: false

  // How close to the bottom counts as "back at the live edge". 8px meant you had to land
  // on the exact last pixel to resume following, so scrolling down to catch up left the
  // feed detached and reading as if follow were broken.
  readonly property int bottomSlack: 48

  function _atBottom() {
    if (!view) return true
    return view.contentY >= _bottomY() - bottomSlack
  }

  // The true max scroll. Exact, because every row is realized (contentHeight includes
  // the header/footer items). Late in-place growth can still leave contentHeight stale
  // for a frame — the slqs snapToBottom fallback positions by item geometry then.
  function _bottomY() {
    // originY-aware: the header item shifts the content origin, so without it the
    // "bottom" lands one header short and returnToBounds clamps the difference.
    return view.originY + Math.max(0, view.contentHeight - view.height)
  }
  function _pin() {
    if (!view || !chatVisible || view.count <= 0) return
    var li = view.itemAtIndex(view.count - 1)
    if (li && li.y + li.height > view.contentHeight + 0.5) {
      view.positionViewAtIndex(view.count - 1, ListView.Beginning)
      view.positionViewAtEnd()
    } else {
      view.contentY = _bottomY()
      view.returnToBounds()
    }
  }

  // Content grew or the viewport resized (chin/composer growth shrinks the view) —
  // while stuck, stay at the bottom. These two connections ARE the follow behavior.
  readonly property Connections _follow: Connections {
    target: sm.view
    enabled: sm.chatVisible && sm._stick
    function onContentHeightChanged() { sm._pin() }
    function onHeightChanged() { sm._pin() }
  }

  // ── events ────────────────────────────────────────────────────────────────────

  // The wheel: ScrollFeel writes contentY directly, so it sets neither `dragging` nor
  // `flicking` and its signal is the only reliable "the user scrolled".
  function userScrolled(up) { _stick = !up && _atBottom() }

  // Drag/flick ended. These two are user-gesture-only, unlike movementStarted/Ended,
  // which Flickable also emits for programmatic contentY changes.
  function gestureStarted() { _stick = false }
  function gestureEnded()   { _stick = _atBottom() }

  // A row was added or removed. While following, the cursor moves with the bottom:
  // leaving it behind put the highlight on an old row while the viewport showed the
  // newest one, so `k` then jumped from a position the user could no longer see.
  function contentChanged() {
    if (!chatVisible || !_stick) return
    wantCursorAtEnd(false)
  }

  // The feed model finished reconciling (streaming tick, or a switch's first load).
  function synced() {
    if (!chatVisible) return
    if (_pendingCursor && view && view.count > 0) {
      _pendingCursor = false
      wantCursorAtEnd(true)
    }
    if (_stick) _pin()
  }

  // Stay where the caller is about to put us. Used when switching to a session whose
  // reading position we remember — the restore itself is the rail's anchor machinery,
  // which only runs while free.
  function hold() { _stick = false; _pendingCursor = false }

  // Jump to the newest content (session switch, send). The pin is immediate AND armed:
  // rows that realize later re-pin through the follow connection above, so there is no
  // settle burst — every growth step lands exactly.
  function toEnd() {
    _stick = true
    _pendingCursor = true
    _pin()
  }

  // The cursor moved to `idx`. Landing on the last row means "follow the stream"; any
  // other row is a deliberate move away from the bottom — reveal it, exactly once.
  function cursorMoved(idx, isLast) {
    if (!chatVisible || !view) return
    if (isLast) {
      _stick = true
      _pin()
      return
    }
    _stick = false
    view.positionViewAtIndex(idx, ListView.Contain)
  }
}

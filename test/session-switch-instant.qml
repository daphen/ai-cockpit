import QtQuick
import Quickshell
import QsLib
import "."

ShellRoot {
  id: test
  function check(ok, message) { if (!ok) { console.error("Error: " + message); Qt.exit(1) } }
  function transcript(sid) {
    var entries = [], parent = null
    for (var i = 0; i < (sid === "beta" && test.betaMoved ? 31 : 30); i++) {
      var u = sid + "u" + i, a = sid + "a" + i
      entries.push({ type: "message", id: u, parentId: parent, message: { role: "user", timestamp: i * 10, content: [{ type: "text", text: sid + " question " + i }] } })
      entries.push({ type: "message", id: a, parentId: u, message: { role: "assistant", timestamp: i * 10 + 5, content: [{ type: "text", text: (sid + " answer " + i + ". ").repeat(30) }] } })
      parent = a
    }
    return JSON.stringify({ type: "response", command: "get_entries", success: true, session: sid, data: { entries: entries, leafId: parent } })
  }
  AgentdState {
    id: state
    selectedSession: rail.selectedRaw
    function send(message) {
      if (message.type === "get_entries") test.fetches.push(message.session)
      if (message.type === "get_entries") { var line = test.transcript(message.session); Qt.callLater(() => state.onLine(line, 0)) }
      return true
    }
  }
  FloatingWindow {
    visible: true; implicitWidth: 720; implicitHeight: 900
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "switch-instant-test"; focused: true }
  }
  function feedView(item) {
    if (!item) return null
    if (String(item).indexOf("QQuickListView") === 0 && item.count === rail.feedScrollState().count && item.count > 0) return item
    for (var c of item.children || []) { var m = feedView(c); if (m) return m }
    return null
  }
  function newest() {
    var fv = feedView(rail), last = fv ? fv.itemAtIndex(fv.count - 1) : null
    return last && last.turn ? String(last.turn.key || "") : ""
  }
  property string target: ""
  property double t0: 0
  property real lowest: 1
  property int round: 0
  property var times: []
  property var fetches: []
  property int fetchesBefore: 0
  property bool betaMoved: false
  property string stale: ""
  property double lastFrame: 0
  property int worstDuringReorder: 0
  property double reorderAt: 0
  property int cardsAtReorder: -1
  property bool builtDuringSlide: false
  property bool wasFull: false
  property real landedAt: NaN
  property real worstDrift: 0
  Connections { target: rail; function onTabRecencyChanged() { if (test.round > 1) { test.reorderAt = Date.now(); test.cardsAtReorder = rail.feedScrollState().count; test.wasFull = false } } }
  FrameAnimation {
    running: true
    onTriggered: {
      var now = Date.now()
      var lv = test.feedView(rail), li = lv ? lv.itemAtIndex(lv.count - 1) : null
      if (test.reorderAt && test.lastFrame && now - test.reorderAt < 700) test.worstDuringReorder = Math.max(test.worstDuringReorder, now - test.lastFrame)
      if (test.reorderAt && now - test.reorderAt < 650 && lv) {
        if (lv.count !== test.cardsAtReorder && test.wasFull) test.builtDuringSlide = true
        test.cardsAtReorder = lv.count; test.wasFull = lv.contentHeight >= lv.height
      }
      test.lastFrame = now
      if (li && !isNaN(test.landedAt) && !test.t0) test.worstDrift = Math.max(test.worstDrift, Math.abs(li.y - lv.contentY - test.landedAt))
      if (!test.t0) return
      var fv = test.feedView(rail)
      if (fv) test.lowest = Math.min(test.lowest, fv.opacity)
      var key = test.newest()
      if (test.betaMoved && test.target === "beta" && key.indexOf("beta") === 0 && key.indexOf("betaa30") !== 0) test.stale = key
      if (key.indexOf(test.target) === 0 && (!test.betaMoved || key.indexOf("betaa30") === 0)) { test.times.push(Date.now() - test.t0); test.t0 = 0; var nv = test.feedView(rail); test.landedAt = nv.itemAtIndex(nv.count - 1).y - nv.contentY }
    }
  }
  Timer {
    interval: 1500; repeat: true; running: true
    onTriggered: {
      var r = test.round++
      if (r === 0) {
        state.onLine(JSON.stringify({ type: "roster", sessions: [{ id: "alpha", name: "alpha", cwd: "/tmp", status: "idle" }, { id: "beta", name: "beta", cwd: "/tmp", status: "idle" }] }), 0)
        rail.activeRaw = "alpha"
      } else if (r < 5) {
        if (r === 3) test.fetchesBefore = test.fetches.length
        test.target = r % 2 ? "beta" : "alpha"; test.t0 = Date.now(); rail.activeRaw = test.target
      } else if (r === 5) {
        test.check(test.fetches.length === test.fetchesBefore, "revisiting a session with nothing new refetched its transcript: " + JSON.stringify(test.fetches.slice(test.fetchesBefore)))
        // Beta moves on while alpha is on screen.
        test.betaMoved = true
        state.onLine(JSON.stringify({ type: "message_end", session: "beta", message: { role: "user", timestamp: 300, content: [{ type: "text", text: "beta question 30" }] } }), 0)
        state.onLine(JSON.stringify({ type: "message_end", session: "beta", message: { role: "assistant", timestamp: 305, content: [{ type: "text", text: "beta answer 30." }] } }), 0)
      } else if (r === 6) {
        test.target = "beta"; test.t0 = Date.now(); rail.activeRaw = "beta"
      } else if (r < 12 && rail.feedScrollState().count < rail.groupedFeed.length) {
      } else {
        test.check(!test.stale, "switching to a session that moved on showed its old cards first (newest was " + test.stale + ")")
        test.check(test.times.length === 5, "a switch never showed the other session's cards: " + JSON.stringify(test.times))
        // The first visit to beta waits for its transcript; the later ones have cards on hand.
        var revisits = test.times.slice(2, 4)
        test.check(test.worstDrift < 2, "the newest card moved " + Math.round(test.worstDrift) + "px on screen after a switch showed it")
        test.check(!test.builtDuringSlide, "off-screen cards were built while the session tabs were sliding")
        test.check(test.worstDuringReorder < 50, "a frame took " + test.worstDuringReorder + "ms while the session list reorders after a switch")
        test.check(Math.max(...revisits) < 600, "switching back to a session took " + JSON.stringify(revisits) + "ms to show its newest card")
        test.check(test.lowest >= 0.99, "the chat faded out during a switch (opacity " + test.lowest + ")")
        test.check(rail.feedScrollState().count === rail.groupedFeed.length, "all cards should be built after the switch, got " + rail.feedScrollState().count + " of " + rail.groupedFeed.length)
        console.log("PASS: switching sessions shows the other session's newest card in " + JSON.stringify(revisits) + "ms without a fade")
        Qt.quit()
      }
    }
  }
}

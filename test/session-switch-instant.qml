import QtQuick
import Quickshell
import QsLib
import "."

ShellRoot {
  id: test
  function check(ok, message) { if (!ok) { console.error("Error: " + message); Qt.exit(1) } }
  function transcript(sid) {
    var entries = [], parent = null
    for (var i = 0; i < 30; i++) {
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
  FrameAnimation {
    running: test.t0 > 0
    onTriggered: {
      var fv = test.feedView(rail)
      if (fv) test.lowest = Math.min(test.lowest, fv.opacity)
      if (test.newest().indexOf(test.target) === 0) { test.times.push(Date.now() - test.t0); test.t0 = 0 }
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
        test.target = r % 2 ? "beta" : "alpha"; test.t0 = Date.now(); rail.activeRaw = test.target
      } else {
        test.check(test.times.length === 4, "a switch never showed the other session's cards: " + JSON.stringify(test.times))
        // The first visit to beta waits for its transcript; the later ones have cards on hand.
        var revisits = test.times.slice(2)
        test.check(Math.max(...revisits) < 400, "switching back to a session took " + JSON.stringify(revisits) + "ms to show its newest card")
        test.check(test.lowest >= 0.99, "the chat faded out during a switch (opacity " + test.lowest + ")")
        test.check(rail.feedScrollState().count === 60, "all cards should be built after the switch, got " + rail.feedScrollState().count)
        console.log("PASS: switching sessions shows the other session's newest card in " + JSON.stringify(revisits) + "ms without a fade")
        Qt.quit()
      }
    }
  }
}

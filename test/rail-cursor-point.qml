import QtQuick
import QtTest
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  AgentdState { id: state; selectedSession: rail.selectedRaw; function send(message) { return true } }
  FloatingWindow {
    visible: true; width: 720; height: 700
    Rail {
      id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "cursor-point-test"; focused: true
      onRequestFocus: forceActiveFocus()
      TestEvent { id: input }
    }
  }
  function check(value, message) { if (!value) throw new Error(message) }
  function event(message) { state.onLine(JSON.stringify(Object.assign({ session: "worker" }, message)), 0) }
  function msgs(n) {
    var e = [], parent = null
    for (var k = 0; k < n; k++) { e.push({ type: "message", id: "m" + k, parentId: parent, message: { role: k % 2 ? "assistant" : "user", content: [{ type: "text", text: "Message number " + k }] } }); parent = "m" + k }
    return { type: "response", command: "get_entries", data: { leafId: parent, entries: e } }
  }
  Timer {
    interval: 400; repeat: true; running: true
    onTriggered: {
      var p = test.phase++
      if (p === 0) {
        test.event({ type: "roster", sessions: [{ id: "worker", name: "worker", cwd: "/tmp", status: "idle" }] })
        rail.jumpToSession("worker")
        test.event(test.msgs(120))
      } else if (p === 3) {
        rail.forceActiveFocus()
        input.keyClick(Qt.Key_Escape, Qt.NoModifier, 0)
        input.keyClick(Qt.Key_K, Qt.NoModifier, 0)
      } else if (p === 4) {
        // The focus glide flies the cursor dot to this point; null means no animation.
        var key = rail.cursorKey
        check(key.indexOf("f:") === 0, "setup: k should land on a transcript row, got " + key)
        check(!!rail.cursorPoint(key), "the cursor row has no dot position, so moving with j/k cannot animate")
        console.log("PASS: a long transcript's cursor row reports where the dot should glide")
        Qt.quit()
      }
    }
  }
}

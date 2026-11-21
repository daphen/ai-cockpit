import QtQuick
import Quickshell
import QsLib
import "."

ShellRoot {
  id: test
  function check(ok, message) { if (!ok) { console.error("Error: " + message); Qt.exit(1) } }
  AgentdState { id: state; function send(message) { return true } }
  FloatingWindow {
    visible: true; implicitWidth: 1000; implicitHeight: 900
    ActivityStream { id: page; anchors.fill: parent; agentd: state; sessions: state.sessions }
  }
  // Two weeks of asks and outcomes across a few busy sessions, like a real activity file.
  function history() {
    var out = [], t = Date.now() - 13 * 86400000
    for (var i = 0; i < 1200; i++) {
      var sid = "s" + (i % 4), at = t + i * 900000
      out.push({ key: "prompt:" + i, sid: sid, at: at, kind: "prompt", from: "you", text: "Ask number " + i })
      out.push({ key: "summary:" + i, sid: sid, at: at + 60000, kind: "summary", text: "Did thing " + i })
      if (i % 3 === 0) out.push({ key: "edit:" + i, sid: sid, at: at + 30000, kind: "edit", path: "/r/F" + i + ".qml", add: 2, del: 1, line: 1, diff: ["-1 old", "+1 new " + i], why: "" })
    }
    return out
  }
  property int phase: 0
  Timer {
    interval: 400; repeat: true; running: true
    onTriggered: {
      var p = test.phase++
      if (p === 0) state._noteActivity(test.history())
      else if (p === 2) {
        var worst = 0
        for (var k = 0; k < 3; k++) {
          var t0 = Date.now()
          state._noteActivity([{ key: "edit:new" + k, sid: "s1", at: Date.now(), kind: "edit", path: "/r/New" + k + ".qml", add: 1, del: 0, line: 1, diff: ["+1 x"], why: "" }])
          page.rows.length
          worst = Math.max(worst, Date.now() - t0)
        }
        test.check(page.cards.length > 50, "setup: expected a long activity list, got " + page.cards.length)
        test.check(worst < 60, "one new change froze the window for " + worst + "ms while Activity rebuilt")
        console.log("PASS: a new change updates Activity in " + worst + "ms with two weeks of history")
        Qt.quit()
      }
    }
  }
}

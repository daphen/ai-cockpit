import QtQuick
import Quickshell
import QsLib
import "."

ShellRoot {
  id: test
  function check(ok, message) { if (!ok) { console.error("Error: " + message); Qt.exit(1) } }
  AgentdState { id: state; function send(message) { return true } }
  FloatingWindow {
    visible: true; implicitWidth: 1000; implicitHeight: 700
    ActivityStream { id: page; anchors.fill: parent; agentd: state; sessions: state.sessions }
  }
  function find(item, pred) { if (!item) return null; if (pred(item)) return item; for (var c of item.children || []) { var m = find(c, pred); if (m) return m } return null }
  function list() { return find(page, i => String(i).indexOf("QQuickListView") === 0) }
  // Even asks were steered past before the agent closed them, so they have edits but no outcome.
  function ask(i, at) {
    var rows = [{ key: "prompt:" + i, sid: "s1", at: at, kind: "prompt", from: "you", text: "Ask number " + i },
                { key: "edit:" + i, sid: "s1", at: at + 1000, kind: "edit", path: "/r/F" + i + ".qml", add: 3, del: 1, line: 1, diff: ["-1 old", "+1 new " + i, "+2 more", "+3 lines"], why: "" }]
    if (i % 2) rows.push({ key: "summary:" + i, sid: "s1", at: at + 2000, kind: "summary", text: "Did thing " + i })
    return rows
  }
  function lastOnScreen() { var v = list(), li = v.itemAtIndex(v.count - 1); return li ? li.y - v.contentY : NaN }
  property var drift: []
  property real rest: 0
  property int before: 0
  property int phase: 0
  Timer { interval: 16; repeat: true; running: test.phase >= 5; onTriggered: test.drift.push(test.lastOnScreen() - test.rest) }
  Timer {
    interval: 400; repeat: true; running: true
    onTriggered: {
      var p = test.phase++, v = test.list()
      if (p === 0) {
        state.sessions = [{ name: "s1", status: "idle" }]
        var rows = []
        for (var i = 0; i < 12; i++) rows = rows.concat(test.ask(i, Date.now() - 3600000 + i * 60000))
        state._noteActivity(rows)
      } else if (p === 2) {
        var j = {}
        for (var c of page.cards) j[c.jid] = { key: 0.1 }
        page.jev = j
        page.importantOnly = false
      } else if (p === 4) {
        test.check(v.contentHeight > v.height, "setup: the list should overflow")
        test.check(Math.abs(v.contentY - (v.originY + v.contentHeight - v.height)) < 1, "setup: should start at the bottom")
        test.rest = test.lastOnScreen()
        test.before = page.rows.length
        state.sessions = [{ name: "s1", status: "streaming" }]
      } else if (p === 6) {
        test.check(page.rows.length === test.before, "sending brought back " + (page.rows.length - test.before) + " rows of older unfinished asks")
        var worst = Math.max(...test.drift.map(Math.abs))
        test.check(worst < 2, "sending moved the visible cards " + Math.round(worst) + "px")
        console.log("PASS: sending a message leaves Activity's cards where they are")
        Qt.quit()
      }
    }
  }
}

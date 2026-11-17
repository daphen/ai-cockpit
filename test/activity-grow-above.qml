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
  function ask(i, at) {
    return [{ key: "prompt:" + i, sid: "s" + (i % 2), at: at, kind: "prompt", from: "you", text: "Ask number " + i },
            { key: "edit:" + i, sid: "s" + (i % 2), at: at + 1000, kind: "edit", path: "/r/F" + i + ".qml", add: 3, del: 1, line: 1, diff: ["-1 old", "+1 new " + i, "+2 more", "+3 lines"], why: "" },
            { key: "summary:" + i, sid: "s" + (i % 2), at: at + 2000, kind: "summary", text: "Did thing " + i }]
  }
  function lastOnScreen() { var v = list(), li = v.itemAtIndex(v.count - 1); return li ? li.y - v.contentY : NaN }
  property var drift: []
  property real rest: 0
  property real h0: 0
  property real grewBy: 0
  property int phase: 0
  Timer { interval: 16; repeat: true; running: test.phase >= 5; onTriggered: test.drift.push(test.lastOnScreen() - test.rest) }
  Timer {
    interval: 400; repeat: true; running: true
    onTriggered: {
      var p = test.phase++, v = test.list()
      if (p === 0) {
        var rows = []
        for (var i = 0; i < 12; i++) rows = rows.concat(test.ask(i, Date.now() - 3600000 + i * 60000))
        state._noteActivity(rows)
      } else if (p === 4) {
        test.check(v.contentHeight > v.height, "setup: the list should overflow")
        test.check(Math.abs(v.contentY - (v.originY + v.contentHeight - v.height)) < 1, "setup: should start at the bottom")
        test.rest = test.lastOnScreen()
        var h0 = v.contentHeight
        state._noteActivity([{ key: "summary:late", sid: "s1", at: Date.now() - 3600000 + 60000 + 3000, kind: "summary", text: "A much longer outcome that arrives late for an older ask. ".repeat(8) }])
        test.grewBy = 0
        test.h0 = h0
      } else if (p === 6) {
        test.check(v.contentHeight > test.h0 + 20, "setup: the older card should have grown, grew " + (v.contentHeight - test.h0))
        test.check(Math.abs(v.contentY - (v.originY + v.contentHeight - v.height)) < 1, "Activity should still sit at the bottom")
        var worst = Math.max(...test.drift.map(Math.abs))
        test.check(worst < 2, "a card growing above the screen pushed the visible cards " + Math.round(worst) + "px before they slid back")
        console.log("PASS: a card growing above the screen leaves the visible cards still")
        Qt.quit()
      }
    }
  }
}

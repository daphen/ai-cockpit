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
  function list() { return find(page, i => String(i).indexOf("QQuickListView") === 0) }
  function find(item, pred) {
    if (!item) return null
    if (pred(item)) return item
    for (var c of item.children || []) { var m = find(c, pred); if (m) return m }
    return null
  }
  function ask(i, at) {
    return [{ key: "prompt:" + i, sid: "s" + (i % 2), at: at, kind: "prompt", from: "you", text: "Ask number " + i },
            { key: "edit:" + i, sid: "s" + (i % 2), at: at + 1000, kind: "edit", path: "/r/F" + i + ".qml", add: 3, del: 1, line: 1, diff: ["-1 old", "+1 new " + i, "+2 more", "+3 lines"], why: "" },
            { key: "summary:" + i, sid: "s" + (i % 2), at: at + 2000, kind: "summary", text: "Did thing " + i }]
  }
  property var ys: []
  property real startY: 0
  property int phase: 0
  Timer { interval: 16; repeat: true; running: test.phase >= 5; onTriggered: test.ys.push(test.list().contentY) }
  Timer {
    interval: 400; repeat: true; running: true
    onTriggered: {
      var p = test.phase++, v = test.list()
      if (p === 0) { var rows = []; for (var i = 0; i < 12; i++) rows = rows.concat(test.ask(i, Date.now() - 3600000 + i * 60000)); state._noteActivity(rows) }
      else if (p === 4) {
        test.check(v.contentHeight > v.height, "setup: the list should overflow")
        test.startY = v.contentY
        test.check(Math.abs(v.contentY - (v.originY + v.contentHeight - v.height)) < 1, "setup: should start at the bottom")
        state._noteActivity(test.ask(12, Date.now() - 1000))
      } else if (p === 6) {
        var end = v.originY + v.contentHeight - v.height
        test.check(end > test.startY + 40, "setup: a new card should grow the list, grew " + (end - test.startY))
        test.check(Math.abs(v.contentY - end) < 1, "after the glide Activity should sit at the bottom, is " + (end - v.contentY) + "px short")
        var between = test.ys.filter(y => y > test.startY + 2 && y < end - 2).length
        test.check(between >= 3, "a new card should slide in smoothly, saw " + between + " in-between frames")
        console.log("PASS: a new Activity card slides the list to the bottom instead of jumping")
        Qt.quit()
      }
    }
  }
}

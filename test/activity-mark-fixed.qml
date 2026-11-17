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
  function mark() { return find(page, i => i.objectName === "activityEndMark") }
  function list() { return find(page, i => i.objectName === "activityList") }
  property var at: null
  property int phase: 0
  Timer {
    interval: 400; repeat: true; running: true
    onTriggered: {
      var p = test.phase++
      if (p === 0) {
        var rows = []
        for (var i = 0; i < 12; i++) rows.push({ key: "prompt:" + i, sid: "s1", at: Date.now() - 3600000 + i * 60000, kind: "prompt", from: "you", text: "Ask " + i },
          { key: "edit:" + i, sid: "s1", at: Date.now() - 3600000 + i * 60000 + 1000, kind: "edit", path: "/r/F" + i + ".qml", add: 2, del: 1, line: 1, diff: ["-1 a", "+1 b", "+2 c"], why: "" })
        state._noteActivity(rows)
      } else if (p === 3) {
        test.check(test.mark(), "no corner mark on the Activity page")
        test.at = test.mark().mapToItem(page, 0, 0)
        test.list().contentY -= 300
      } else if (p === 4) {
        var now = test.mark().mapToItem(page, 0, 0)
        test.check(Math.abs(now.y - test.at.y) < 0.5 && Math.abs(now.x - test.at.x) < 0.5, "the corner mark moved with the list by " + Math.round(now.y - test.at.y) + "px")
        test.check(now.x + test.mark().width <= page.width && now.y + test.mark().height <= page.height, "the mark should sit inside the bottom-right corner")
        var m = test.mark(), l = test.list(), kids = m.parent.children, mi = -1, li = -1
        for (var k = 0; k < kids.length; k++) { if (kids[k] === m) mi = k; if (kids[k] === l) li = k }
        test.check(m.parent === l.parent && (m.z < l.z || (m.z === l.z && mi < li)), "the cards should slide over the mark, not under it")
        console.log("PASS: the Activity mark stays fixed in the corner behind the cards while the list scrolls")
        Qt.quit()
      }
    }
  }
}

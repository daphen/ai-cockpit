import QtQuick
import Quickshell
import QsLib
import "."

ShellRoot {
  id: test
  function check(ok, message) { if (!ok) { console.error("Error: " + message); Qt.exit(1) } }
  function event(message) { state.onLine(JSON.stringify(message), 0) }
  AgentdState { id: state; function send(message) { return true } }
  FloatingWindow {
    visible: true; implicitWidth: 1000; implicitHeight: 700
    ActivityStream { id: page; anchors.fill: parent; agentd: state; sessions: state.sessions }
  }
  function find(item, pred) { if (!item) return null; if (pred(item)) return item; for (var c of item.children || []) { var m = find(c, pred); if (m) return m } return null }
  function labels(name) {
    var list = find(page, i => String(i).indexOf("QQuickListView") === 0), out = []
    ;(function walk(it) {
      if (!it) return
      if (it.objectName === "writtenLabel" && it.visible) out.push(it)
      for (var c of it.children || []) walk(c)
    })(list.contentItem)
    return out
  }
  property int phase: 0
  Timer {
    interval: 400; repeat: true; running: true
    onTriggered: {
      var p = test.phase++
      if (p === 0) {
        test.event({ type: "message_end", session: "s1", message: { role: "user", timestamp: Date.now(), content: [{ type: "text", text: "Add a script and tweak the sync" }] } })
        test.event({ type: "tool_execution_start", session: "s1", toolName: "write", toolCallId: "w1", args: { path: "/r/activate.py", content: "print(1)\n" } })
        test.event({ type: "tool_execution_end", session: "s1", toolName: "write", toolCallId: "w1", result: { content: [{ type: "text", text: "Successfully wrote 9 bytes to /r/activate.py" }] } })
        test.event({ type: "tool_execution_start", session: "s1", toolName: "edit", toolCallId: "e1", args: { path: "/r/sync.go", edits: [] } })
        test.event({ type: "tool_execution_end", session: "s1", toolName: "edit", toolCallId: "e1", result: { details: { diff: "-12 old := 1\n+12 changed := delta" } } })
        test.event({ type: "message_end", session: "s1", message: { role: "assistant", timestamp: Date.now(), content: [{ type: "text", text: "\u27e2 Added the script and tweaked the sync." }] } })
      } else if (p === 3) {
        var files = page.rows.filter(r => r.kind === "file").map(r => r.f.name + (r.f.written ? ":written" : ""))
        test.check(files.indexOf("activate.py:written") >= 0, "a file written in one go should be marked as written, got " + JSON.stringify(files))
        test.check(files.indexOf("sync.go") >= 0, "an edited file should not be marked as written, got " + JSON.stringify(files))
        test.check(test.labels().length === 1, "exactly one file row should show the written label, got " + test.labels().length)
        console.log("PASS: a file written in one go shows a written label instead of an empty row")
        Qt.quit()
      }
    }
  }
}

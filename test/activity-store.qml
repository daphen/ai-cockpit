import QtQuick
import Quickshell
import Quickshell.Io
import QsLib
import "."

ShellRoot {
  id: test
  readonly property string store: Quickshell.env("XDG_RUNTIME_DIR") + "/activity.json"
  function fail(message) { console.error("Error: " + message); Qt.quit() }
  AgentdState { id: first; activityStorePath: test.store; function send(message) { return true } }
  Loader { id: later; active: false; sourceComponent: AgentdState { activityStorePath: test.store; function send(message) { return true } } }
  property int stage: 0
  Timer {
    running: true; repeat: true; interval: 500
    onTriggered: {
      if (test.stage === 0) {
        first.onLine(JSON.stringify({ type: "roster", sessions: [{ id: "gone", name: "gone", cwd: "/r", status: "idle" }] }), 0)
        first.onLine(JSON.stringify({ type: "response", command: "get_entries", session: "gone", success: true, data: { entries: [
          { type: "message", id: "a1", message: { role: "assistant", timestamp: Date.now() - 60000, content: [
            { type: "toolCall", id: "e1", name: "edit", arguments: { path: "/r/Kept.qml", edits: [] } }] } },
          { type: "message", id: "r1", message: { role: "toolResult", toolCallId: "e1", timestamp: Date.now() - 59000, details: { diff: "+ 1 kept" } } }] } }), 0)
        if (!first.activity.some(r => r.path === "/r/Kept.qml")) test.fail("history did not load")
      } else if (test.stage === 5) {
        // A new Cockpit: the session is gone from agentd, so its transcript can't be asked for.
        later.active = true
      } else if (test.stage === 7) {
        if (!later.item.activity.some(r => r.sid === "gone" && r.path === "/r/Kept.qml"))
          test.fail("a closed session's activity should survive a Cockpit restart")
        console.log("PASS: activity outlives the sessions it came from")
        Qt.quit()
      }
      test.stage++
    }
  }
}

import QtQuick
import Quickshell
import "."

ShellRoot {
  id: test
  function check(ok, message) { if (!ok) { console.error("Error: " + message); Qt.exit(1) } }
  AgentdState { id: state; function send(message) { return true } }
  // A long session: big tool results with deeply nested details, ending on an unanswered question.
  function transcript() {
    var entries = []
    for (var i = 0; i < 600; i++) {
      var id = "call" + i, nested = []
      for (var k = 0; k < 120; k++) nested.push({ line: k, spans: [{ text: "x" + k, style: { bold: k % 2 === 0 } }] })
      entries.push({ id: "a" + i, type: "message", message: { role: "assistant", timestamp: i,
        content: [{ type: "text", text: "Step " + i }, { type: "toolCall", id: id, name: "bash", arguments: { command: "ls" } }] } })
      entries.push({ id: "r" + i, type: "message", message: { role: "toolResult", toolCallId: id, toolName: "bash", timestamp: i,
        content: [{ type: "text", text: "ok" }], details: { rows: nested } } })
    }
    entries.push({ id: "q", type: "message", message: { role: "assistant", timestamp: 999,
      content: [{ type: "toolCall", id: "ask1", name: "ask_user", arguments: { kind: "confirm", title: "Ship it?", message: "Ready?" } }] } })
    return entries
  }
  Timer {
    interval: 300; running: true
    onTriggered: {
      state.sessions = [{ id: "s1", name: "s1", status: "idle" }]
      state.selectedSession = "s1"
      var line = JSON.stringify({ type: "response", command: "get_entries", success: true, session: "s1", data: { entries: test.transcript(), leafId: "q" } })
      var best = Infinity
      for (var run = 0; run < 3; run++) {
        var t0 = Date.now()
        state.onLine(line, 0)
        best = Math.min(best, Date.now() - t0)
      }
      var ask = state.staleAskFor("s1")
      test.check(ask && ask.title === "Ship it?", "the unanswered question at the end of the transcript should be recovered, got " + JSON.stringify(ask))
      test.check(best < 150, "reloading a long transcript blocked the window for " + best + "ms")
      console.log("PASS: reloading a long transcript takes " + best + "ms and still recovers the open question")
      Qt.quit()
    }
  }
}

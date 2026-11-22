import QtQuick
import Quickshell
import "."
ShellRoot {
  id: test
  property int rebuilds: 0
  AgentdState {
    id: state
    function send(message) { return true }
    onSessionsChanged: test.rebuilds++
  }
  function roster(status, tool, cost, ask) {
    state.onLine(JSON.stringify({ type: "roster", sessions: [
      { id: "a", name: "a", cwd: "/tmp/a", status: status, currentTool: tool, costUsd: cost, ask: { title: ask || "Ship?" } },
      { id: "b", name: "b", cwd: "/tmp/b", status: "idle", costUsd: 0 }] }), 0)
  }
  function check(ok, message) { if (!ok) { console.error("Error: " + message); Qt.exit(1) } }
  Timer {
    interval: 100; running: true
    onTriggered: {
      test.roster("streaming", "bash", 0.5)
      var base = test.rebuilds
      test.roster("streaming", "read", 0.7)
      test.check(test.rebuilds === base, "a tool or cost change rebuilt the session list")
      state.onLine(JSON.stringify({ type: "roster", sessions: [
        { id: "b", name: "b", cwd: "/tmp/b", status: "idle", costUsd: 0 },
        { id: "a", name: "a", cwd: "/tmp/a", status: "streaming", currentTool: "read", costUsd: 0.7, ask: { title: "Ship?" } }] }), 0)
      test.check(test.rebuilds === base, "agentd's reshuffled session order rebuilt the session list")
      test.check(state.curToolFor("a") === "read", "the running tool did not update: " + state.curToolFor("a"))
      test.roster("streaming", "read", 0.7, "Deploy?")
      test.check(test.rebuilds === base + 1, "a changed question did not rebuild the session list")
      test.check(state.sessions[0].ask.title === "Deploy?", "the new question did not reach the session list")
      console.log("PASS: tool, cost and order churn skip the session-list rebuild; real changes still apply")
      Qt.quit()
    }
  }
}

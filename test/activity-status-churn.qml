import QtQuick
import Quickshell
import "."
ShellRoot {
  id: test
  property int rebuilds: 0
  AgentdState { id: state; function send(message) { return true } }
  AgentdState { id: railState; function send(message) { return true } }
  Rail { id: rail; visible: false; width: 400; height: 400; agentd: railState; scopeMode: "personal"; instanceName: "activity-churn-test" }
  ActivityStream {
    id: page
    visible: false
    agentd: state
    sessions: state.sessions
    rail: rail
    onChangesChanged: test.rebuilds++
  }
  // No socket is connected here, so every session reads as offline; a question
  // appearing is the session change that reaches the list.
  function roster(ask, cwd) {
    state.onLine(JSON.stringify({ type: "roster", sessions: [
      { id: "a", name: "a", cwd: cwd || "/tmp/a", status: "idle", ask: ask ? { title: ask } : null },
      { id: "b", name: "b", cwd: "/tmp/b", status: "idle" }] }), 0)
  }
  property bool failed: false
  function check(ok, message) { if (!ok && !failed) { failed = true; console.error("Error: " + message); Qt.exit(1) } }
  Timer {
    interval: 100; running: true
    onTriggered: {
      page.repos = { "/tmp/a": { top: "/tmp/a", commits: [] }, "/tmp/a2": { top: "/tmp/a", commits: [] } }
      test.roster("")
      var base = test.rebuilds, list = state.gen
      test.roster("Ship?")
      test.roster("")
      test.check(state.gen === list + 2, "the session list did not change, so this test proves nothing")
      test.check(test.rebuilds === base, "a session's state change rebuilt the activity timeline " + (test.rebuilds - base) + " times")
      test.roster("", "/tmp/a2")
      test.check(test.rebuilds > base, "a session moving to another folder did not rebuild the activity timeline")
      if (!test.failed) console.log("PASS: session state changes leave the activity timeline alone; a folder change still rebuilds it")
      Qt.quit()
    }
  }
}

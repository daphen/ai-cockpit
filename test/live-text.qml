import QtQuick
import Quickshell
import "."

ShellRoot {
  id: test
  property int phase: 0
  property int activeRequests: 0
  property int hiddenRequests: 0
  AgentdState {
    id: active
    scope: "personal"
    configuredSockPaths: [Quickshell.env("HOME") + "/../agentd-personal.sock"]
    selectedSession: rail.selectedRaw
    function send(message) { if (message.type === "get_entries") test.activeRequests++; return true }
  }
  AgentdState {
    id: hidden
    configuredSockPaths: [Quickshell.env("HOME") + "/../agentd-personal.sock"]
    selectedSession: "ticket-a"
    function send(message) { if (message.type === "get_entries") test.hiddenRequests++; return true }
  }
  FloatingWindow {
    visible: true
    width: 600; height: 700
    Rail { id: rail; anchors.fill: parent; agentd: active; scopeMode: "personal"; instanceName: "live-text-test"; focused: true }
  }
  function broadcast(message) {
    var line = JSON.stringify(message)
    active.onLine(line, 0); hidden.onLine(line, 0)
  }
  function check(ok, message) { if (!ok) throw new Error(message) }
  Timer {
    interval: 150; running: true; repeat: true
    onTriggered: {
      if (test.phase === 0) {
        test.broadcast({ type: "roster", sessions: [{ id: "ticket-a", name: "ticket-a", cwd: "/tmp/fixture", status: "streaming" }] })
      } else if (test.phase === 1) {
        test.broadcast({ type: "response", command: "get_entries", session: "ticket-a", data: { entries: [] } })
        hidden.selectedSession = ""
        test.activeRequests = 0; test.hiddenRequests = 0
        test.broadcast({ type: "message_start", session: "ticket-a", message: { role: "assistant" } })
        test.broadcast({ type: "message_update", session: "ticket-a", assistantMessageEvent: { type: "text_delta", delta: "Streamed " } })
      } else if (test.phase === 2) {
        rail.debugNav("G")
      } else if (test.phase === 3) {
        test.check(rail.probeProse().indexOf("Streamed") >= 0, "rendered Rail did not show text before completion: " + JSON.stringify({ selected: rail.selectedRaw, cur: rail.cur, rows: rail.fSize, prose: rail.probeProse() }))
        test.broadcast({ type: "message_update", session: "ticket-a", assistantMessageEvent: { type: "text_delta", delta: "answer." } })
      } else if (test.phase === 4) {
        test.check(rail.probeProse().indexOf("Streamed answer.") >= 0, "rendered Rail did not update partial text")
        test.broadcast({ type: "message_end", session: "ticket-a", message: { role: "assistant", content: [{ type: "text", text: "Streamed answer." }] } })
        test.broadcast({ type: "turn_end", session: "ticket-a" })
        test.check(test.activeRequests === 0 && test.hiddenRequests === 0, "tool round triggered history fetch")
        test.broadcast({ type: "agent_end", session: "ticket-a" })
        test.check(test.activeRequests === 1 && test.hiddenRequests === 0, "inactive client duplicated final history fetch")
        running = false
        console.log("PASS: rendered streaming text and active-scope history ownership (4 checks)")
      }
      test.phase++
    }
  }
}

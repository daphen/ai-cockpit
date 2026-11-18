import QtQuick
import Quickshell
import Quickshell.Io
import QsLib
import "."

ShellRoot {
  id: test
  function check(ok, message) { if (!ok) { console.error("Error: " + message); Qt.exit(1) } }
  function event(message) { state.onLine(JSON.stringify(message), 0) }
  property int publishes: 0
  AgentdState { id: state; function send(message) { return true } }
  FloatingWindow {
    visible: true; implicitWidth: 1000; implicitHeight: 700
    ActivityStream { id: page; anchors.fill: parent; agentd: state; sessions: state.sessions }
  }
  Connections { target: page; function onJevChanged() { test.publishes++ } }
  FileView { id: cache; path: Quickshell.env("HOME") + "/.cache/cockpit/jev-activity.json"; blockWrites: true; atomicWrites: false }
  property int phase: 0
  Timer {
    interval: 500; repeat: true; running: true
    onTriggered: {
      var p = test.phase++
      if (p === 0) Quickshell.execDetached(["mkdir", "-p", Quickshell.env("HOME") + "/.cache/cockpit"])
      else if (p === 1) {
        for (var i = 0; i < 40; i++) {
          test.event({ type: "message_end", session: "s1", message: { role: "user", timestamp: 1000 + i * 10, content: [{ type: "text", text: "Change number " + i }] } })
          test.event({ type: "tool_execution_start", session: "s1", toolName: "edit", toolCallId: "e" + i, args: { path: "/r/f" + i + ".go", edits: [] } })
          test.event({ type: "tool_execution_end", session: "s1", toolName: "edit", toolCallId: "e" + i, result: { details: { diff: "-1 old := " + i + "\n+1 next := " + i } } })
          test.event({ type: "message_end", session: "s1", message: { role: "assistant", timestamp: 1005 + i * 10, content: [{ type: "text", text: "\u27e2 Changed " + i + "." }] } })
        }
        var scores = {}
        for (var c of page.cards) scores[c.jid] = { key: 0.2 }
        test.check(Object.keys(scores).length >= 30, "expected dozens of cards to score, got " + Object.keys(scores).length)
        test.scores = scores
        cache.setText(JSON.stringify(scores))
      } else if (p === 13) {
        var want = Object.keys(test.scores).length, scored = page.cards.filter(c => c.jid in page.jev).length
        test.check(scored === want, "every card should get its score, got " + scored + " of " + want + " after " + test.publishes + " updates")
        test.check(test.publishes === 1, "scores arriving in batches should reach the screen once, not " + test.publishes + " times")
        console.log("PASS: dozens of scores in several batches reach Activity in one update")
        Qt.quit()
      }
    }
  }
  property var scores: ({})
}

import QtQuick
import Quickshell
import QsLib
import "."

ShellRoot {
  id: test
  property var requested: []
  function fail(message) { console.error("Error: " + message); Qt.quit() }
  FloatingWindow {
    visible: true; implicitWidth: 1100; implicitHeight: 900
    Dashboard {
      id: dash
      anchors.fill: parent
      focusedSession: "ai-cockpit"
      sessions: [{ name: "ai-cockpit", scope: "personal", status: "streaming", cwd: "/home/u/personal/ai-cockpit" },
                 { name: "nixos", scope: "personal", status: "idle", cwd: "/home/u/nixos" }]
      model: ({ scope: "personal", kind: "session", tabs: ["plan", "tests", "changes"], activeTab: "plan",
                cards: [{ title: "PLAN", rows: [] }] })
      onActionRequested: id => test.requested.push(id)
    }
  }
  Timer {
    property int stage: 0
    interval: 200; repeat: true; running: true
    onTriggered: {
      if (stage === 0) {
        if (String(dash.tabs) !== "sessions,changes,tests") test.fail("tabs were " + dash.tabs)
        if (!dash.showSessions || dash.workers.length !== 2) test.fail("selected private session did not show every session card")
        if (dash.ticketState("nixos").label !== "~/nixos") test.fail("private card status was " + dash.ticketState("nixos").label)
        dash.dispatch("tab:changes")
        if (String(test.requested) !== "tab:changes") test.fail("changes tab did not ask Neovim for the changes view")
        if (!dash.showSessions) test.fail("showed the plan view under the Changes tab before Neovim answered")
        dash.model = Object.assign({}, dash.model, { activeTab: "changes", cards: [{ title: "CHANGES", rows: [] }] })
      } else if (stage === 1) {
        if (dash.showSessions || dash.activeTab !== "changes") test.fail("changes view did not replace the cards")
        dash.dispatch("tab:sessions")
        if (!dash.showSessions || dash.activeTab !== "sessions") test.fail("sessions tab did not bring the cards back")
        dash.model = { scope: "personal", kind: "session", tabs: ["plan"], activeTab: "plan", cards: [] }
        if (String(dash.tabs) !== "sessions") test.fail("a session without changes or tests still offered them")
        console.log("PASS: private dashboard shows session cards with Changes/Tests tabs")
        Qt.quit()
      }
      stage++
    }
  }
}

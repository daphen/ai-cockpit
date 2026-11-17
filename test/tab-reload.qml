import QtQuick
import Quickshell
import "."
ShellRoot {
  id: test
  PersistentProperties { id: life; reloadableId: "tab-reload-test"; property int n: 0 }
  function fail(msg) { console.log("Error: " + msg); Qt.exit(1) }
  AgentdState { id: state; selectedSession: rail.selectedRaw; function send(message) { return true } }
  FloatingWindow { visible: true; width: 900; height: 900
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "tab-reload-test"; focused: false
           nvimSock: "/tmp/tab-reload-absent.sock"; reportedTab: "code" }
  }
  Timer { interval: 600; running: true
    onTriggered: {
      if (life.n === 0) {
        if (rail.workspaceTab !== "activity") { test.fail("startup tab is " + rail.workspaceTab + ", wanted activity"); return }
        life.n = 1
        rail.workspaceTab = "code"
        Quickshell.reload(false)
        return
      }
      if (life.n === 1) {
        if (rail.workspaceTab !== "code") { test.fail("a reload on Code reopened " + rail.workspaceTab); return }
        life.n = 2
        rail.showWorkspace("activity", true)
        Quickshell.reload(false)
        return
      }
      rail.reportedTab = "vault"
      if (rail.workspaceTab !== "activity") { test.fail("after a reload the tab is " + rail.workspaceTab); return }
      console.log("PASS: Cockpit starts on Activity, and a hot reload keeps whichever tab was open")
      Qt.quit()
    }
  }
}

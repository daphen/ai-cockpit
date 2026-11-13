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
        life.n = 1
        rail.showWorkspace("activity", true)
        Quickshell.reload(false)
        return
      }
      rail.reportedTab = "vault"
      if (rail.workspaceTab !== "activity") { test.fail("after a reload the tab is " + rail.workspaceTab); return }
      console.log("PASS: the activity tab survives a hot reload even when the editor then reports another view")
      Qt.quit()
    }
  }
}

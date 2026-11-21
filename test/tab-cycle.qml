import QtQuick
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  function fail(msg) { console.log("FAIL: " + msg); Qt.exit(1) }
  function expect(tab, label) { if (rail.workspaceTab !== tab) fail(label + ": tab is " + rail.workspaceTab + ", wanted " + tab) }
  AgentdState { id: state; selectedSession: rail.selectedRaw; function send(message) { return true } }
  FloatingWindow { visible: true; width: 900; height: 900
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "tab-cycle-test"; focused: false
           nvimSock: "/tmp/tab-cycle-absent.sock"; reportedTab: "code" }
  }
  Timer { interval: 300; repeat: true; running: true
    onTriggered: {
      if (test.phase === 0) {
        state.onLine(JSON.stringify({type:"roster",sessions:[{id:"one",name:"one",cwd:Quickshell.env("HOME") + "/tab-cycle",status:"idle",plan:"p"}]}),0)
        rail.jumpToSession("one")
      // After the rail's startup landings (500/1000/1500ms), which re-request the open tab.
      } else if (test.phase === 8) {
        rail.showWorkspace("dashboard"); test.expect("dashboard", "first press")
        rail.showWorkspace("vault"); test.expect("vault", "second quick press")
        rail.reportedTab = "dashboard"; test.expect("vault", "late report of the first press")
        rail.reportedTab = "vault"; test.expect("vault", "editor confirms")
        rail.reportedTab = "dashboard"; test.expect("dashboard", "editor changes view itself")
        rail.showWorkspace("plan"); test.expect("plan", "unconfirmed press")
      } else if (test.phase === 20) {
        test.expect("dashboard", "unconfirmed press falls back to the editor's view")
        rail.showWorkspace("activity", true); test.expect("activity", "activity press")
        rail.jumpToSession("one"); rail.landNvim("one")
        rail.reportedTab = "code"; test.expect("activity", "switching sessions keeps the activity tab")
        rail.showWorkspace("code", true); test.expect("code", "leaving activity")
        console.log("PASS: tab presses lead, late reports are ignored, editor-side changes are adopted, activity stays put across session switches")
        Qt.quit()
      }
      test.phase++
    }
  }
}

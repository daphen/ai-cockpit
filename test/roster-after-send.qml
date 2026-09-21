import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import "."
ShellRoot {
  id: test
  property int phase: 0
  SocketServer { active: true; path: Quickshell.env("HOME") + "/agentd-work.sock"; handler: Socket {} }
  AgentdState {
    id: backend
    configuredSockPaths: [Quickshell.env("HOME") + "/agentd-work.sock"]
    selectedSession: rail.selectedRaw
    function send(message) { return true }
  }
  FloatingWindow {
    visible: true; implicitWidth: 720; implicitHeight: 800
    Rail { id: rail; anchors.fill: parent; agentd: backend; scopeMode: "work"; instanceName: "roster-after-send"; focused: true; TestEvent { id: keys } }
  }
  Timer {
    interval: 400; running: true; repeat: true
    onTriggered: {
      if (test.phase === 0) {
        if (!backend.connected) return
        backend.onLine(JSON.stringify({type:"roster",sessions:["alpha","beta","gamma"].map(n=>({id:n,name:n,cwd:"/isolated",status:"idle"}))}),0)
        rail.jumpToSession("alpha")
      } else if (test.phase === 1) {
        rail.prefillComposer("Diagnostic prompt"); keys.keyClick(Qt.Key_Return,Qt.NoModifier,0)
      } else if (test.phase === 2) {
        rail.focusRoster()
        if (rail.cur !== 0 || rail.insert) { console.error("roster entry did not select its first row"); Qt.quit(); return }
      } else if (test.phase === 3) {
        if (rail.cur !== 0 || rail.insert) { console.error("delayed feed update pulled the cursor out of the roster"); Qt.quit(); return }
        keys.keyClick(Qt.Key_J,Qt.NoModifier,0)
        if (rail.cur !== 1) { console.error("roster did not receive navigation"); Qt.quit(); return }
        console.log("PASS: roster selection and navigation survive the next feed update after sending")
        Qt.quit()
      }
      test.phase++
    }
  }
}

import QtQuick
import Quickshell
import Quickshell.Io
import "."
ShellRoot {
  id: test
  property bool ready: false
  property int phase: 0
  readonly property var rail: loader.item
  Process {
    running: true
    command: ["sh","-c",'mkdir -p "$HOME/.local/state/cockpit"; printf work > "$HOME/.local/state/cockpit/orchestrator-holder"; printf lovable > "$HOME/.local/state/cockpit/selected-default-test-work"']
    onExited: (code, status) => { if (code) throw new Error("fixture setup failed"); test.ready = true }
  }
  SocketServer { active: true; path: Quickshell.env("HOME") + "/agentd-lovable.sock"; handler: Socket {} }
  SocketServer { active: true; path: Quickshell.env("HOME") + "/agentd-work.sock"; handler: Socket {} }
  AgentdState {
    id: backend
    configuredSockPaths: [Quickshell.env("HOME") + "/agentd-lovable.sock",Quickshell.env("HOME") + "/agentd-work.sock"]
    selectedSession: test.rail ? test.rail.selectedRaw : ""
    function send(message) { return true }
  }
  FloatingWindow {
    visible: true; implicitWidth: 720; implicitHeight: 800
    Loader {
      id: loader; anchors.fill: parent; active: test.ready
      sourceComponent: Component { Rail { agentd: backend; scopeMode: "work"; instanceName: "default-test" } }
    }
  }
  function remote(worker) {
    var rows = [{id:"orchestrator",name:"orchestrator",profile:"lovable-orchestrator",cwd:"/remote/src/lovable",status:"idle"}]
    if (worker) rows.push({id:"aaa-worker",name:"aaa-worker",profile:"lovable-worker",cwd:"/remote/src/worker",status:"idle"})
    backend.onLine(JSON.stringify({type:"roster",sessions:rows}),1)
  }
  Timer {
    interval: 150; running: true; repeat: true
    onTriggered: {
      if (!test.ready || !backend.connected) return
      if (test.phase === 0) {
        backend.onLine(JSON.stringify({type:"roster",sessions:[{id:"lovable",name:"lovable",profile:"lovable-orchestrator",cwd:"/local/lovable",status:"idle"}]}),0)
        test.remote(true); test.phase++
      } else if (test.phase === 1) {
        if (!backend.settled) return
        if (rail.selectedRaw !== "orchestrator") throw new Error("restart restored the retired local orchestrator: " + JSON.stringify({selected:rail.selectedRaw,saved:rail.savedRaw,holder:rail.recordedOrchScope,sessions:backend.sessions}))
        rail.jumpToSession("aaa-worker"); test.remote(true); test.phase++
      } else if (test.phase === 2) {
        if (rail.selectedRaw !== "aaa-worker") throw new Error("roster update stole explicit worker selection")
        loader.active = false; test.phase++
      } else if (test.phase === 3) { loader.active = true; test.phase++ }
      else if (test.phase === 4) {
        if (rail.selectedRaw !== "aaa-worker") throw new Error("restart lost the saved worker selection: " + rail.selectedRaw)
        loader.active = false; test.remote(false); test.phase++
      } else if (test.phase === 5) { loader.active = true; test.phase++ }
      else if (test.phase === 6) {
        if (rail.selectedRaw !== "orchestrator") throw new Error("missing saved session did not fall back to the active orchestrator")
        console.log("PASS: startup follows handover owner, rejects retired defaults, preserves explicit and saved worker selections")
        Qt.quit()
      }
    }
  }
}

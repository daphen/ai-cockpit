import QtQuick
import Quickshell
import Quickshell.Io
import "."
ShellRoot {
  id: test
  property int phase: 0
  SocketServer { active: true; path: Quickshell.env("HOME") + "/peer.sock"; handler: Socket {} }
  AgentdState { id: state; configuredSockPaths: [Quickshell.env("HOME") + "/peer.sock"]; selectedSession: rail.selectedRaw; function send(message) { return true } }
  Process {
    running: true; stdinEnabled: true
    command: ["nvim", "--headless", "-u", "NONE", "--listen", Quickshell.env("HOME") + "/nvim.sock", "--cmd",
      'lua package.preload["cockpit"]=function() return {workspace=function(...) vim.fn.writefile({vim.json.encode({...})},os.getenv("HOME").."/workspace-call") end} end']
  }
  FileView { id: calls; path: Quickshell.env("HOME") + "/workspace-call"; blockAllReads: true; printErrors: false }
  FloatingWindow {
    visible: true; implicitWidth: 720; implicitHeight: 800
    Rail { id: rail; anchors.fill: parent; scopeMode: "work"; instanceName: "orchestrator-test"; agentd: state; nvimSock: Quickshell.env("HOME") + "/nvim.sock" }
  }
  Timer {
    interval: 100; running: true; repeat: true
    onTriggered: {
      if (test.phase === 0) {
        if (!state.connected) return
        state.onLine(JSON.stringify({type:"roster",sessions:[
          {id:"conductor",name:"conductor",cwd:"/remote-host/src/lovable",profile:"lovable-orchestrator",status:"idle"},
          {id:"worker",name:"worker",cwd:"/remote-host/src/lovable",profile:"lovable-worker",status:"idle"}
        ]}),0)
        rail.jumpToSession("conductor"); test.phase++; return
      }
      calls.reload()
      var text = calls.text()
      if (!text) return
      var args = JSON.parse(text)
      if (test.phase === 1 && args[1] === "conductor") {
        if (args[2] !== "/remote-host/src/lovable" || args[6] !== "lovable-orchestrator") throw new Error("orchestrator landing lost its remote cwd or role: " + text)
        rail.jumpToSession("worker"); test.phase++
      } else if (test.phase === 2 && args[1] === "worker") {
        if (args[6] !== "lovable-worker") throw new Error("worker landing lost its role")
        console.log("PASS: selected session role and truthful remote cwd reach the bound Neovim dashboard")
        Qt.quit()
      }
    }
  }
}

import QtQuick
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  readonly property string reason: "Our servers are currently overloaded. Please try again later."
  AgentdState { id: state; selectedSession: rail.selectedRaw; function send(message) { return true } }
  FloatingWindow { visible: true; width: 650; height: 800
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "error-proof" }
  }
  function visibleText(item) {
    if (!item || item.visible === false) return ""
    var text = typeof item.text === "string" ? item.text : ""
    for (var i = 0; item.children && i < item.children.length; i++) text += "\n" + visibleText(item.children[i])
    return text
  }
  Timer { interval: 200; repeat: true; running: true
    onTriggered: {
      if (test.phase === 0) state.onLine(JSON.stringify({type:"roster",sessions:[{id:"nixos",name:"nixos",cwd:"/tmp",status:"idle"}]}),0)
      else if (test.phase === 1) {
        rail.jumpToSession("nixos")
        state.onLine(JSON.stringify({type:"response",command:"get_entries",session:"nixos",data:{leafId:"error",entries:[
          {type:"message",id:"user",parentId:null,message:{role:"user",content:[{type:"text",text:"status?"}]}},
          {type:"message",id:"error",parentId:"user",message:{role:"assistant",content:[],stopReason:"error",errorMessage:test.reason}}
        ]}}),0)
      } else if (test.phase === 4) {
        if (test.visibleText(rail).indexOf(test.reason) < 0) throw new Error("provider failure remains hidden in collapsed activity")
        if (Object.keys(rail.expandedGroups).length) throw new Error("test unexpectedly expanded a disclosure")
        console.log("PASS: actual provider error visible without opening activity disclosure")
        Qt.quit()
      }
      test.phase++
    }
  }
}

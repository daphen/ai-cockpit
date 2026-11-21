import QtQuick
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  readonly property string stalled: "the model was silent for 45s, so the stall guard cancelled this turn"
  AgentdState { id: state; selectedSession: rail.selectedRaw; function send(message) { return true } }
  FloatingWindow { visible: true; width: 650; height: 800
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "stall-proof" }
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
        state.onLine(JSON.stringify({type:"response",command:"get_entries",session:"nixos",data:{leafId:"other",entries:[
          {type:"message",id:"user",parentId:null,message:{role:"user",content:[{type:"text",text:"status?"}]}},
          {type:"custom",id:"mark",parentId:"user",customType:"stall-guard-abort",data:{seconds:45}},
          {type:"message",id:"stall",parentId:"mark",message:{role:"assistant",content:[],stopReason:"aborted"}},
          {type:"message",id:"user2",parentId:"stall",message:{role:"user",content:[{type:"text",text:"again"}]}},
          {type:"message",id:"other",parentId:"user2",message:{role:"assistant",content:[],stopReason:"aborted"}}
        ]}}),0)
      } else if (test.phase === 4) {
        var text = test.visibleText(rail)
        if (text.indexOf(test.stalled) < 0) throw new Error("stall-guard abort is not named as a stall")
        if (text.split("aborted externally").length !== 2) throw new Error("only the unmarked abort should read as external")
        console.log("PASS: stall-guard abort is named; an unmarked abort still reads as external")
        Qt.quit()
      }
      test.phase++
    }
  }
}

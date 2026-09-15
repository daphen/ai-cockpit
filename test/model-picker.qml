import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import "."

ShellRoot {
  id: test
  property int phase: 0
  property var sent: []
  property bool allowSend: true
  SocketServer { active: true; path: Quickshell.env("HOME") + "/agentd-personal.sock"; handler: Socket {} }
  AgentdState {
    id: state
    configuredSockPaths: [Quickshell.env("HOME") + "/agentd-personal.sock"]
    selectedSession: rail.selectedRaw
    function send(message) { if (!test.allowSend) return false; test.sent = test.sent.concat([message]); return true }
  }
  FloatingWindow {
    visible: true; implicitWidth: 720; implicitHeight: 800
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "model-picker-test"; focused: true; TestEvent { id: input } }
  }
  function check(value, message) { if (!value) throw new Error(message) }
  function event(message) { state.onLine(JSON.stringify(message), 0) }
  function roster(model) { event({type:"roster",sessions:[{id:"target",name:"target",cwd:"/tmp",status:"idle",model:model}]}) }
  function textItem(item, text) {
    if (item.text === text) return item
    for (var child of item.children || []) { var found = textItem(child, text); if (found) return found }
    return null
  }
  Timer {
    interval: 250; repeat: true; running: true
    onTriggered: {
      if (test.phase === 0) { if (!state.connected) return; test.roster("openai/gpt-5.6-sol") }
      else if (test.phase === 1) {
        rail.jumpToSession("target"); rail.toggleModelPicker()
        test.event({type:"response",command:"get_available_models",session:"target",data:{models:[{provider:"openai",id:"gpt-5.6-sol"},{provider:"openai",id:"gpt-6-astra"}]}})
      } else if (test.phase === 2) {
        var item = test.textItem(rail,"gpt-6-astra")
        test.check(item !== null, "model choice did not render")
        input.mouseClick(item, 10, item.height/2, Qt.LeftButton, Qt.NoModifier, 0)
      } else if (test.phase === 3) {
        var request = test.sent.filter(item => item.type === "set_model").pop()
        test.check(request && request.session === "target" && request.provider === "openai" && request.modelId === "gpt-6-astra", "click did not send the selected model")
        test.check(!rail.modelOpen && rail.selectedModelLabel === "GPT 5.6 SOL", "selection was applied before server confirmation")
        test.roster("openai/gpt-6-astra")
        test.event({type:"response",command:"set_model",session:"target",success:true,data:{provider:"openai",id:"gpt-6-astra"}})
      } else if (test.phase === 4) {
        test.check(rail.selectedModelLabel === "GPT 6 ASTRA", "authoritative roster did not update footer")
        test.check(test.textItem(rail,"Model changed: gpt-6-astra") !== null, "successful model change has no feedback")
        rail.toggleModelPicker(); rail.chooseModel(0)
        test.event({type:"response",command:"set_model",session:"target",success:false,error:"Model unavailable"})
      } else if (test.phase === 5) {
        test.check(rail.selectedModelLabel === "GPT 6 ASTRA", "failed switch changed the model label")
        test.check(test.textItem(rail,"Model change failed: Model unavailable") !== null, "server error was hidden")
        test.allowSend = false; rail.toggleModelPicker(); rail.chooseModel(0)
      } else if (test.phase === 6) {
        test.check(rail.modelOpen && test.textItem(rail,"Model change not sent: daemon disconnected") !== null, "disconnected click failed silently")
        console.log("PASS: actual model click, confirmed footer, success/error feedback and disconnected selection")
        Qt.quit()
      }
      test.phase++
    }
  }
}

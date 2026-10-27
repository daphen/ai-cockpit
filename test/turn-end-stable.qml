import QtQuick
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  property int before: -1
  readonly property string answer: "The answer streams in and stays put when the turn ends."
  AgentdState { id: state; selectedSession: rail.selectedRaw; function send(message) { return true } }
  FloatingWindow {
    visible: true; width: 720; height: 800
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "turn-end-test"; focused: true }
  }
  function check(value, message) { if (!value) throw new Error(message) }
  function event(message) { state.onLine(JSON.stringify(message), 0) }
  function delta(type, text) { event({type:"message_update",session:"worker",assistantMessageEvent:{type:type,delta:text,contentIndex:0},message:{model:"m"}}) }
  Timer {
    interval: 250; repeat: true; running: true
    onTriggered: {
      if (test.phase === 0) test.event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"streaming"}]})
      else if (test.phase === 1) {
        rail.jumpToSession("worker")
        test.event({type:"response",command:"get_entries",session:"worker",data:{leafId:"u",entries:[
          {type:"message",id:"u",parentId:null,message:{role:"user",content:[{type:"text",text:"Explain"}]}}]}})
      } else if (test.phase === 2) {
        test.delta("thinking_start", "")
        test.delta("thinking_delta", "**Weighing the options** carefully")
      } else if (test.phase === 3) {
        test.delta("text_start", "")
        test.delta("text_delta", test.answer)
      } else if (test.phase === 6) {
        test.before = rail.probeCardCreates
        var content = [{type:"thinking",thinking:"**Weighing the options** carefully"},{type:"text",text:test.answer}]
        test.event({type:"message_end",session:"worker",message:{role:"assistant",model:"m",content:content}})
        test.event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle"}]})
        test.event({type:"response",command:"get_entries",session:"worker",data:{leafId:"a",entries:[
          {type:"message",id:"u",parentId:null,message:{role:"user",content:[{type:"text",text:"Explain"}]}},
          {type:"message",id:"a",parentId:"u",message:{role:"assistant",model:"m",content:content}}]}})
      } else if (test.phase === 9) {
        test.check(rail.groupedFeed.every(row => String(row.key).indexOf("live:") < 0 && String(row.key).indexOf("think:") < 0), "transcript did not replace the live rows")
        var created = rail.probeCardCreates - test.before
        test.check(created === 0, "ending the turn recreated " + created + " cards that were already on screen")
        console.log("PASS: ending a turn keeps the streamed reasoning and answer cards in place")
        Qt.quit()
      }
      test.phase++
    }
  }
}

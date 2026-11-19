import QtQuick
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  readonly property string lost: "You back?"
  AgentdState { id: state; selectedSession: "w"; function send(message) { return true } }
  function event(message) { state.onLine(JSON.stringify(message), 0) }
  function check(value, message) { if (!value) throw new Error(message) }
  function row() { return state.feedFor("w").find(item => item.kind === "user" && item.text === test.lost) }
  function entries() {
    return {type:"response",command:"get_entries",session:"w",success:true,data:{trimmedFrom:900,entries:[
      {type:"message",id:"a",timestamp:new Date(Date.now() - 60000).toISOString(),
       message:{role:"assistant",content:[{type:"text",text:"Done."}]}}]}}
  }
  Timer {
    interval: test.phase === 1 ? 3200 : 100; running: true; repeat: true
    onTriggered: {
      if (test.phase === 0) {
        test.event({type:"roster",sessions:[{id:"w",name:"w",cwd:"/tmp",status:"streaming"}]})
        state.steer("w", test.lost)
        for (const m of state._localEcho["w"]) test.event({type:"response",command:"steer",session:"w",id:m.id,success:true})
        test.event({type:"turn_end",session:"w"})
        test.event({type:"agent_end",session:"w",messages:[]})
        test.event({type:"roster",sessions:[{id:"w",name:"w",cwd:"/tmp",status:"idle"}]})
        test.event(test.entries())
        test.check(test.row() && test.row().delivery !== "failed", "message marked lost before the run had time to record it")
      } else if (test.phase === 1) {
        test.event(test.entries())
        test.check(test.row() && test.row().delivery === "failed", "message pi never recorded stays pinned as delivered")
        test.event({type:"response",command:"get_entries",session:"w",success:true,data:{entries:[
          {type:"message",id:"u",timestamp:new Date().toISOString(),message:{role:"user",content:[{type:"text",text:test.lost}]}}]}})
        test.check(state.feedFor("w").filter(item => item.kind === "user" && item.text === test.lost).length === 1, "recorded message duplicated")
        console.log("PASS: a steer pi drops after its run ends is offered for resend instead of sticking")
        Qt.quit()
      }
      test.phase++
    }
  }
}

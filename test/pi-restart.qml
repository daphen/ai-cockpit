import QtQuick
import Quickshell
import "."
ShellRoot {
  id: test
  readonly property string lost: "Shape the new cycle"
  readonly property string kept: "Already in the transcript"
  AgentdState { id: state; selectedSession: "orch"; function send(message) { return true } }
  function event(message) { state.onLine(JSON.stringify(message), 0) }
  function check(value, message) { if (!value) throw new Error(message) }
  function user(text) { return state.feedFor("orch").find(item => item.kind === "user" && item.text === text) }
  Timer {
    interval: 100; running: true
    onTriggered: {
      test.event({type:"roster",sessions:[{id:"orch",name:"orch",cwd:"/tmp",status:"streaming"}]})
      state.steer("orch", test.kept)
      state.steer("orch", test.lost)
      for (const m of state._localEcho["orch"]) test.event({type:"response",command:"steer",session:"orch",id:m.id,success:true})
      test.event({type:"response",command:"get_entries",session:"orch",data:{entries:[
        {type:"message",id:"u",message:{role:"user",content:[{type:"text",text:test.kept}]}}]}})
      test.event({type:"queue_update",session:"orch",steering:[test.lost],followUp:[]})
      state.interrupt("orch")
      test.check(state.feedFor("orch").some(item => item.tool === "queue"), "queue line not shown before restart")

      test.event({type:"reconnecting",session:"orch"})
      test.check(!state.feedFor("orch").some(item => item.tool === "queue"), "dead pi's queue line survived the restart")
      test.check(!state.isInterrupting("orch"), "interrupt still waits for a pi that no longer exists")
      test.check(test.user(test.lost) && test.user(test.lost).delivery === "failed", "unwritten steer not offered for resend")
      test.check(test.user(test.kept) && test.user(test.kept).delivery !== "failed", "written steer wrongly marked failed")
      console.log("PASS: pi restart clears its queue and interrupt, and offers unwritten steers for resend")
      Qt.quit()
    }
  }
}

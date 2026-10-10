import QtQuick
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  property bool online: true
  readonly property string prompt: "Check the other session's question card"
  readonly property string rejection: "The daemon explicitly rejected this request"
  AgentdState { id: state; selectedSession: "worker"; function send(message) { return test.online } }
  function event(message) { state.onLine(JSON.stringify(message), 0) }
  function check(value, message) { if (!value) throw new Error(message) }
  Timer {
    interval: test.phase === 1 ? 31050 : 100; running: true; repeat: true
    onTriggered: {
      if (test.phase === 0) {
        test.event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"streaming"}]})
        state.sendPrompt("worker", test.prompt)
        test.event({type:"prompt_accepted",session:"worker",message:test.prompt,steered:true})
      } else if (test.phase === 1) {
        test.event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle"}]})
        test.event({type:"response",command:"get_entries",session:"worker",data:{entries:[]}})
        var waiting = state.feedFor("worker")
        test.check(!waiting.some(item => String(item.text || "").indexOf("not delivered") >= 0), "stale transcript invented a delivery failure for an accepted message")
        test.check(waiting.filter(item => item.kind === "user" && item.text === test.prompt).length === 1, "accepted message vanished before transcript confirmation")
      } else if (test.phase === 2) {
        test.event({type:"response",command:"get_entries",session:"worker",data:{entries:[
          {type:"message",id:"u",message:{role:"user",content:[{type:"text",text:test.prompt}]}}
        ]}})
        test.check(state.feedFor("worker").filter(item => item.kind === "user" && item.text === test.prompt).length === 1, "confirmed message was duplicated")
        test.event({type:"error",session:"worker",error:test.rejection})
        test.check(state.feedFor("worker").some(item => item.tool === "error" && item.text === test.rejection), "explicit error was hidden")
        test.online = false
        state.sendPrompt("worker", "Disconnected request")
        test.check(state.feedFor("worker").some(item => item.tool === "error" && String(item.text).indexOf("not delivered") >= 0), "disconnected transport failure was hidden")
        test.check(state.feedFor("worker").some(item => item.kind === "user" && item.text === "Disconnected request" && item.delivery === "failed"), "disconnected local copy lacks a not-delivered tag")
        console.log("PASS: stale idle transcript does not invent delivery failure; accepted echo survives, confirmation deduplicates, explicit and disconnected errors remain")
        Qt.quit()
      }
      test.phase++
    }
  }
}

import QtQuick
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  readonly property string handoff: "⇄ nixos\nUser explicitly approved sending BOTH current-session UI issues to YOU"
  readonly property string localPrompt: "Keep this local steer visible"
  AgentdState { id: state; selectedSession: "ai-cockpit"; function send(message) { return true } }
  function event(message) { state.onLine(JSON.stringify(message), 0) }
  function snapshot() {
    event({type:"response",command:"get_entries",session:"ai-cockpit",data:{entries:[
      {type:"message",id:"canonical",message:{role:"user",content:[{type:"text",text:"Canonical latest message"}]}}
    ]}})
  }
  function userCount(text) {
    return state.feedFor("ai-cockpit").filter(item => item.kind === "user" && item.text === text).length
  }
  function check(value, message) { if (!value) throw new Error(message) }
  Timer {
    interval: 100; running: true; repeat: true
    onTriggered: {
      if (test.phase === 0) {
        test.event({type:"roster",sessions:[{id:"ai-cockpit",name:"ai-cockpit",cwd:"/tmp",status:"streaming"}]})
        test.snapshot()
        test.event({type:"prompt_accepted",session:"ai-cockpit",message:test.handoff,steered:true})
        test.check(test.userCount(test.handoff) === 1, "live handoff was not shown once")
      } else if (test.phase === 1) {
        test.snapshot()
        test.check(test.userCount(test.handoff) === 0, "non-canonical handoff was re-appended after the first history snapshot")
        test.event({type:"tool_execution_start",session:"ai-cockpit",toolName:"read",toolCallId:"read-1",args:{path:"/tmp/file"}})
        test.snapshot()
        test.check(test.userCount(test.handoff) === 0, "non-canonical handoff returned after a repeated history snapshot")
      } else if (test.phase === 2) {
        state.steer("ai-cockpit", test.localPrompt)
        test.event({type:"prompt_accepted",session:"ai-cockpit",message:test.localPrompt,steered:true})
        test.snapshot()
        test.snapshot()
        test.check(test.userCount(test.localPrompt) === 1, "locally sent steer did not survive repeated stale history snapshots")
        test.check(state.feedFor("ai-cockpit").filter(item => item.kind === "user").slice(-1)[0].text === test.localPrompt,
                   "local steer lost canonical tail ordering")
        console.log("PASS: remote handoff is not retained as a local echo; locally sent steer survives repeated stale snapshots")
        Qt.quit()
      }
      test.phase++
    }
  }
}

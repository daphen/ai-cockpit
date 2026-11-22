import QtQuick
import Quickshell
import "."
ShellRoot {
  id: test
  property var sent: []
  AgentdState { id: state; selectedSession: "worker"; function send(message) { test.sent = test.sent.concat([message]); return true } }
  function event(message) { state.onLine(JSON.stringify(message), 0) }
  Timer {
    interval: 100; running: true
    onTriggered: {
      // Pi emits agent_end, then auto-compacts inside the same run, so it is still busy.
      test.event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"streaming"}]})
      test.event({type:"agent_end",session:"worker",messages:[]})
      test.event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle"}]})
      test.event({type:"compaction_start",session:"worker",reason:"threshold"})
      state.sendPrompt("worker", "What's going on here?")
      var prompt = test.sent.filter(m => m.type === "prompt")[0]
      if (!prompt || prompt.streamingBehavior !== "followUp") {
        console.error("Error: a prompt sent while pi may still be busy must ask pi to queue it, got " + JSON.stringify(prompt))
        Qt.exit(1); return
      }
      console.log("PASS: a prompt sent between agent_end and settle is queued by pi instead of rejected")
      Qt.quit()
    }
  }
}

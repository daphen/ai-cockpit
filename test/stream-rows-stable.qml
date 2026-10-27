import QtQuick
import Quickshell
import "."

ShellRoot {
  id: test
  property int phase: 0
  property int waits: 0
  property int firstCreates: -1
  readonly property int tools: 5

  AgentdState { id: state; selectedSession: rail.selectedRaw; function send(message) { return true } }
  FloatingWindow {
    visible: true; width: 720; height: 800
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "stream-rows-test"; focused: true }
  }
  function check(value, message) { if (!value) throw new Error(message) }
  function event(message) { state.onLine(JSON.stringify(message), 0) }
  function tool(n) {
    event({type:"tool_execution_start",session:"worker",toolCallId:"bash-" + n,toolName:"bash",args:{command:"echo " + n}})
  }

  Timer {
    interval: 200; repeat: true; running: true
    onTriggered: {
      if (test.phase === 0) test.event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"streaming"}]})
      else if (test.phase === 1) {
        rail.jumpToSession("worker")
        test.event({type:"response",command:"get_entries",session:"worker",data:{entries:[]}})
        test.event({type:"prompt_accepted",session:"worker",message:"Run the tools"})
      } else if (test.phase === 2) test.tool(1)
      else if (test.phase === 3) {
        if (rail.probeActCreates < 1 && ++test.waits < 12) return
        test.check(rail.probeActCreates >= 1, "first tool row never rendered")
        test.firstCreates = rail.probeActCreates
        test.tool(2)
      } else if (test.phase >= 4 && test.phase <= 6) test.tool(test.phase - 1)
      else if (test.phase === 8) {
        var created = rail.probeActCreates - test.firstCreates
        test.check(created === test.tools - 1,
          "adding " + (test.tools - 1) + " tool calls created " + created + " tool rows; existing rows were rebuilt")
        console.log("PASS: a new tool call adds one row and leaves the existing rows in place")
        Qt.quit()
      }
      test.phase++
    }
  }
}

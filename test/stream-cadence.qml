import QtQuick
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  property int sent: 0
  property bool sawDuringBurst: false
  readonly property string expected: "xxxxxxxxxxxxxxx"
  AgentdState {
    id: active
    selectedSession: rail.selectedRaw
    function send(message) { return true }
  }
  FloatingWindow { visible: true; width: 600; height: 700
    Rail { id: rail; anchors.fill: parent; agentd: active; scopeMode: "personal"; instanceName: "cadence-test"; focused: true }
  }
  function broadcast(message) { active.onLine(JSON.stringify(message), 0) }
  function fail(message) { throw new Error(message) }
  Timer {
    id: setup; interval: 150; repeat: true; running: true
    onTriggered: {
      if (test.phase === 0) test.broadcast({type:"roster",sessions:[{id:"ticket-a",name:"ticket-a",cwd:"/tmp",status:"streaming"}]})
      else if (test.phase === 1) test.broadcast({type:"response",command:"get_entries",session:"ticket-a",data:{entries:[]}})
      else if (test.phase === 2) { setup.stop(); burst.start() }
      test.phase++
    }
  }
  Timer {
    id: burst; interval: 20; repeat: true
    onTriggered: {
      test.broadcast({type:"message_update",session:"ticket-a",assistantMessageEvent:{type:"text_delta",delta:"x"}})
      test.sent++
      if (rail.probeProse().indexOf("x") >= 0) test.sawDuringBurst = true
      if (test.sent >= 15) { burst.stop(); after.start() }
    }
  }
  Timer {
    id: after; interval: 160
    onTriggered: {
      if (!test.sawDuringBurst) test.fail("text stayed hidden during continuous sub-120ms deltas")
      if (rail.probeProse().indexOf(test.expected) < 0) test.fail("final streamed text is incomplete: " + rail.probeProse())
      console.log("PASS: continuous 20ms deltas rendered during the burst and completed correctly")
      Qt.quit()
    }
  }
}

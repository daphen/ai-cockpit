import QtQuick
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  property int sent: 0
  readonly property string expected: "xxxxxxxxxxxxxxx"
  AgentdState {
    id: active
    selectedSession: rail.selectedRaw
    function send(message) { return true }
  }
  FloatingWindow { visible: true; width: 600; height: 700
    Rail { id: rail; anchors.fill: parent; agentd: active; scopeMode: "personal"; instanceName: "typing-test"; focused: true }
  }
  function broadcast(message) { active.onLine(JSON.stringify(message), 0) }
  function check(ok, message) { if (!ok) throw new Error(message) }
  Timer {
    id: setup; interval: 150; repeat: true; running: true
    onTriggered: {
      if (test.phase === 0) test.broadcast({type:"roster",sessions:[{id:"ticket-a",name:"ticket-a",cwd:"/tmp",status:"streaming"}]})
      else if (test.phase === 1) test.broadcast({type:"response",command:"get_entries",session:"ticket-a",data:{entries:[]}})
      else if (test.phase === 2) { setup.stop(); rail.prefillComposer("draft"); burst.start() }
      test.phase++
    }
  }
  Timer {
    id: burst; interval: 20; repeat: true
    onTriggered: {
      test.broadcast({type:"message_update",session:"ticket-a",assistantMessageEvent:{type:"text_delta",delta:"x"}})
      test.sent++
      if (test.sent >= 15) { burst.stop(); held.start() }
    }
  }
  Timer {
    id: held; interval: 170
    onTriggered: {
      test.check(rail.probeProse().indexOf("x") < 0, "streaming prose reflowed while composer held a draft")
      rail.exitInsert()
      flushed.start()
    }
  }
  Timer {
    id: flushed; interval: 170
    onTriggered: {
      test.check(rail.probeProse().indexOf(test.expected) >= 0, "latest prose did not catch up after leaving composer")
      console.log("PASS: streaming feed stayed still during a draft and caught up after insert exit")
      Qt.quit()
    }
  }
}

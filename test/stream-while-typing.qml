import QtQuick
import QtTest
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  property int sent: 0
  property bool sawDuringBurst: false
  property string submitted: ""
  readonly property string expected: "xxxxxxxxxxxxxxx"
  AgentdState {
    id: active
    selectedSession: rail.selectedRaw
    function send(message) {
      if (message.type === "prompt") test.submitted = message.message
      return true
    }
  }
  FloatingWindow { visible: true; width: 600; height: 700
    Rail {
      id: rail; anchors.fill: parent; agentd: active; scopeMode: "personal"; instanceName: "typing-test"; focused: true
      TestEvent { id: input }
    }
  }
  function broadcast(message) { active.onLine(JSON.stringify(message), 0) }
  function check(ok, message) { if (!ok) throw new Error(message) }
  function composer(item) {
    if (item.textDocument && !item.readOnly && item.cursorRectangle !== undefined) return item
    for (var child of item.children || []) { var found = composer(child); if (found) return found }
    return null
  }
  Timer {
    id: setup; interval: 150; repeat: true; running: true
    onTriggered: {
      if (test.phase === 0) test.broadcast({type:"roster",sessions:[{id:"ticket-a",name:"ticket-a",cwd:"/tmp",status:"idle"}]})
      else if (test.phase === 1) test.broadcast({type:"response",command:"get_entries",session:"ticket-a",data:{entries:[]}})
      else if (test.phase === 2) {
        setup.stop()
        rail.prefillComposer("first question")
        input.keyClick(Qt.Key_Return, Qt.NoModifier, 0)
        test.check(test.submitted === "first question" && rail.composerText === "", "first question was not sent")
        rail.prefillComposer("draft")
        burst.start()
      }
      test.phase++
    }
  }
  Timer {
    id: burst; interval: 20; repeat: true
    onTriggered: {
      test.broadcast({type:"message_update",session:"ticket-a",assistantMessageEvent:{type:"text_delta",delta:"x"}})
      input.keyClick(Qt.Key_X, Qt.NoModifier, 0)
      test.sent++
      if (rail.probeProse().indexOf("x") >= 0) test.sawDuringBurst = true
      if (test.sent >= 15) { burst.stop(); held.start() }
    }
  }
  Timer {
    id: held; interval: 170
    onTriggered: {
      test.check(test.sawDuringBurst, "response stayed hidden during continuous typing")
      test.check(rail.probeProse().indexOf(test.expected) >= 0, "response did not finish rendering while typing")
      test.check(rail.insert && test.composer(rail).activeFocus, "streaming took keyboard focus from the composer")
      test.check(rail.composerText === "draft" + test.expected, "streaming lost typed draft characters")
      rail.exitInsert()
      flushed.start()
    }
  }
  Timer {
    id: flushed; interval: 170
    onTriggered: {
      test.check(rail.probeProse().indexOf(test.expected) >= 0, "latest prose did not catch up after leaving composer")
      test.check(rail.composerText === "draft" + test.expected, "leaving insert mode lost the draft")
      console.log("PASS: response streamed during continuous typing immediately after send, preserving focus and every draft character")
      Qt.quit()
    }
  }
}

import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import "."
ShellRoot {
  id: test
  property int phase: 0
  property bool online: true
  property var sent: []
  property string expected: ""
  SocketServer { active: true; path: Quickshell.env("HOME") + "/agentd-work.sock"; handler: Socket {} }
  AgentdState {
    id: backend
    configuredSockPaths: [Quickshell.env("HOME") + "/agentd-work.sock"]
    selectedSession: rail.selectedRaw
    function send(message) { if (!test.online) return false; test.sent = test.sent.concat([message]); return true }
  }
  FloatingWindow {
    visible: true; implicitWidth: 720; implicitHeight: 800
    Rail { id: rail; anchors.fill: parent; agentd: backend; scopeMode: "work"; instanceName: "optimistic-test"; focused: true; TestEvent { id: keys } }
  }
  function check(ok, message) { if (!ok) throw new Error(message) }
  function users(text) { return rail.groupedFeed.filter(row => row.kind === "user" && row.text === text).length }
  function submit(text) {
    rail.prefillComposer(text)
    keys.keyClick(Qt.Key_Return,Qt.NoModifier,0)
    rail.prefillComposer("Already typing the next message")
    test.expected = text; immediate.start()
  }
  Timer {
    id: immediate; interval: 35
    onTriggered: {
      test.check(rail.probeProse().indexOf(test.expected) >= 0, "local message not rendered within 35ms while typing continued: " + rail.probeProse())
      test.check(rail.composerText === "Already typing the next message", "echo refresh disturbed the next draft")
      test.check(test.users(test.expected) === 1, "optimistic message duplicated")
    }
  }
  Timer {
    interval: 180; running: true; repeat: true
    onTriggered: {
      if (test.phase === 0) {
        if (!backend.connected) return
        backend.onLine(JSON.stringify({type:"roster",sessions:[{id:"remote",name:"remote",cwd:"/remote/src/project",status:"idle"}]}),0)
        rail.jumpToSession("remote")
      } else if (test.phase === 1) test.submit("Instant prompt")
      else if (test.phase === 2) {
        test.check(test.sent.filter(m=>m.type === "prompt").length === 1, "prompt did not reach the transport")
        test.submit("Instant steer")
      } else if (test.phase === 3) {
        test.check(test.sent.filter(m=>m.type === "steer").length === 1, "busy submission was not a steer")
        backend.onLine(JSON.stringify({type:"response",command:"get_entries",session:"remote",data:{entries:[
          {id:"one",type:"message",message:{role:"user",content:[{type:"text",text:"Instant prompt"}]}},
          {id:"two",parentId:"one",type:"message",message:{role:"user",content:[{type:"text",text:"Instant steer"}]}}
        ]}}),0)
        rail.prefillComposer("")
      } else if (test.phase === 4) {
        test.check(test.users("Instant prompt") === 1 && test.users("Instant steer") === 1, "delayed history duplicated local echoes: " + JSON.stringify(rail.groupedFeed))
        test.online = false; rail.prefillComposer("Offline message"); keys.keyClick(Qt.Key_Return,Qt.NoModifier,0)
      } else if (test.phase === 5) {
        test.check(test.users("Offline message") === 0, "disconnected write was presented as a sent message")
        test.check(rail.probeProse().toLowerCase().indexOf("error") >= 0, "disconnected error indicator was not immediately visible: " + rail.probeProse())
        console.log("PASS: prompt and steer render within 35ms with no remote response; continued typing, delayed history and disconnected feedback remain correct")
        Qt.quit()
      }
      test.phase++
    }
  }
}

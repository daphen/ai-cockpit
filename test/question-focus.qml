import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import "."

ShellRoot {
  id: test
  property int phase: 0
  property var sent: []
  SocketServer { active: true; path: Quickshell.env("HOME") + "/agentd-personal.sock"; handler: Socket {} }
  AgentdState {
    id: state
    configuredSockPaths: [Quickshell.env("HOME") + "/agentd-personal.sock"]
    selectedSession: rail.selectedRaw
    function send(message) { test.sent = test.sent.concat([message]); return true }
  }
  FloatingWindow {
    visible: true; implicitWidth: 720; implicitHeight: 800
    Rail {
      id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; focused: true
      onRequestFocus: { focused = true; forceActiveFocus() }
    }
    TextInput { id: editor; width: 30; height: 20; anchors.right: parent.right }
  }
  TestEvent { id: input }
  function check(ok, message) { if (!ok) throw new Error(message) }
  function find(item, predicate) {
    if (predicate(item)) return item
    for (var child of item.children || []) { var match = find(child,predicate); if (match) return match }
    return null
  }
  function event(message) { state.onLine(JSON.stringify(message),0) }
  function ask(method, session) {
    event({type:"extension_ui_request",session:session || "target",id:method + phase,method:method,title:"Choose",options:["Alpha","Beta"]})
  }
  function answered(payload, session) { event(Object.assign({type:"ask_answered",session:session || "target"},payload)) }
  function composer() {
    var frame = find(rail,item => item.objectName === "composerFrame")
    return find(frame,item => item.cursorPosition !== undefined && item.readOnly === false)
  }
  function ready() { check(!rail.pendingAsk && rail.insert && composer().activeFocus,"answer did not return actual keyboard focus to composer") }
  Timer {
    interval: 170; repeat: true; running: true
    onTriggered: {
      if (phase === 0) {
        if (!state.connected) return
        test.event({type:"roster",sessions:[{id:"target",name:"target",cwd:"/tmp",status:"idle"},{id:"other",name:"other",cwd:"/tmp",status:"idle"}]})
        rail.jumpToSession("target")
        test.ask("confirm")
      } else if (phase === 1) {
        input.keyClick(Qt.Key_Y,Qt.NoModifier,0)
        test.check(test.sent.some(message => message.type === "answer" && message.response.confirmed === true),"confirmation was not sent")
        test.check(rail.pendingAsk && !rail.insert,"composer focused before answer was accepted")
        test.answered({confirmed:true})
      } else if (phase === 2) {
        test.ready()
        input.keyClick(Qt.Key_X,Qt.NoModifier,0)
        test.check(rail.composerText === "x","typing after answer did not reach composer")
        input.keyClick(Qt.Key_Backspace,Qt.NoModifier,0)
        test.ask("select")
      } else if (phase === 3) {
        var label = test.find(rail,item => item.text === "Beta")
        input.mouseClick(label,5,label.height/2,Qt.LeftButton,Qt.NoModifier,0)
        test.answered({value:"Beta"})
      } else if (phase === 4) {
        test.ready(); test.ask("input")
      } else if (phase === 5) {
        input.keyClick(Qt.Key_X,Qt.NoModifier,0); input.keyClick(Qt.Key_Return,Qt.NoModifier,0)
        test.check(test.sent.some(message => message.type === "answer" && message.response.value === "x"),"text answer was not sent")
        test.answered({value:"x"})
      } else if (phase === 6) {
        test.ready(); test.ask("editor")
      } else if (phase === 7) {
        input.keyClick(Qt.Key_Y,Qt.NoModifier,0); input.keyClick(Qt.Key_Return,Qt.NoModifier,0)
        test.answered({value:"y"})
      } else if (phase === 8) {
        test.ready()
        input.keyClick(Qt.Key_D,Qt.NoModifier,0); input.keyClick(Qt.Key_Escape,Qt.NoModifier,0)
        test.ask("confirm","other")
        state.answerAsk("other",{confirmed:true})
        rail.focused = false; editor.forceActiveFocus()
        test.answered({confirmed:true},"other")
      } else if (phase === 9) {
        test.check(editor.activeFocus && !rail.insert && rail.composerText === "d","background answer stole focus or discarded draft")
        rail.focused = true; rail.forceActiveFocus(); test.ask("confirm")
        test.answered({confirmed:true})
      } else if (phase === 10) {
        test.check(!rail.insert,"answer from another client stole composer focus")
        console.log("PASS: confirmed/select/text/editor replies focus composer after acceptance, actual typing, retained drafts and no background/remote focus theft")
        Qt.quit()
      }
      phase++
    }
  }
}

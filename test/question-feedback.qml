import QtQuick
import QtTest
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  property var sent: []
  property bool connectedSend: true
  AgentdState {
    id: state; selectedSession: rail.selectedRaw
    function send(message) { if (!test.connectedSend) return false; test.sent = test.sent.concat([message]); return true }
  }
  FloatingWindow {
    visible: true; width: 720; height: 900
    Rail {
      id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "question-feedback-test"; focused: true
      onRequestFocus: forceActiveFocus()
      TestEvent { id: input }
    }
  }
  TestCase { id: gui; when: false }
  function check(value,message) { if (!value) throw new Error(message) }
  function find(item,predicate) {
    if (!item || !item.visible) return null
    if (predicate(item)) return item
    for (var child of item.children || []) { var match = find(child,predicate); if (match) return match }
    return null
  }
  function label(text) { return find(rail,item => item.text === text) }
  function event(message) { state.onLine(JSON.stringify(Object.assign({session:"worker"},message)),0) }
  function ask(id,method) { event({type:"extension_ui_request",id:id,method:method || "confirm",title:"Choose",options:["Alpha","Beta"]}) }
  function click(item) { check(item,"reply button missing"); gui.wait(30); input.mouseClick(item,5,item.height/2,Qt.LeftButton,Qt.NoModifier,0) }
  function replies() { return sent.filter(message => message.type === "answer").length }
  Timer {
    interval: 250; repeat: true; running: true
    onTriggered: {
      if (phase === 0) {
        event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle"}]})
        rail.jumpToSession("worker"); ask("first")
      } else if (phase === 1) {
        click(label("yes"))
        check(rail.askSending && label("Sending reply…") && label("Waiting for the agent to confirm receipt…"),"click has no immediate pending feedback")
        check(!label("yes").parent.parent.enabled && label("yes").parent.parent.opacity < 1,"reply buttons remain active while sending")
        input.keyClick(Qt.Key_N,Qt.NoModifier,0)
        check(replies() === 1,"pending keyboard reply was sent twice")
      } else if (phase === 3) {
        check(rail.pendingAsk && rail.askSending,"reply appeared accepted before delayed acknowledgement")
        event({type:"ask_answered",confirmed:true})
        check(!rail.askSending && !rail.pendingAsk,"acknowledged question remained pending")
      } else if (phase === 4) {
        ask("second","select")
      } else if (phase === 5) {
        click(label("Beta")); check(rail.askSending,"select reply has no feedback")
        event({type:"error",error:"Reply rejected by agent"})
        check(!rail.askSending && rail.pendingAsk,"rejection did not restore a retryable question")
      } else if (phase === 6) {
        check(label("Reply rejected by agent"),"rejection was not shown")
        click(label("Alpha")); check(rail.askSending && replies() === 3,"rejected reply cannot be retried")
        event({type:"ask_answered",value:"Alpha"})
      } else if (phase === 7) {
        ask("offline","input"); connectedSend = false
      } else if (phase === 8) {
        input.keyClick(Qt.Key_X,Qt.NoModifier,0); input.keyClick(Qt.Key_Return,Qt.NoModifier,0)
        check(!rail.askSending && rail.pendingAsk,"failed local send left the question disabled")
        check(find(rail,item => item.readOnly === false && item.text === "x"),"failed send erased the answer draft")
        connectedSend = true
      } else if (phase === 9) {
        check(label("Reply not sent — disconnected. Try again."),"failed send has no feedback")
        input.keyClick(Qt.Key_Return,Qt.NoModifier,0)
        check(rail.askSending,"text retry has no pending feedback")
        event({type:"ask_answered",value:"x"})
        ask("replacement")
        check(!rail.askSending && label("needs your input"),"new question inherited old sending state")
        console.log("PASS: immediate button/text feedback, delayed acknowledgement, disabled controls, duplicate suppression, rejection/retry, disconnected-send feedback and retained drafts")
        Qt.quit()
      }
      phase++
    }
  }
}

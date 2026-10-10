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
  readonly property string attachmentMessage: "Inspect @/home/remote/.cache/heidr-pastes/img933.png\n\nSelected code: /remote/src/view.ts:2-3\n```ts\nconst selected = true\n```"
  SocketServer { active: true; path: Quickshell.env("HOME") + "/agentd-work.sock"; handler: Socket {} }
  AgentdState {
    id: state
    configuredSockPaths: [Quickshell.env("HOME") + "/agentd-work.sock"]
    selectedSession: "worker"
    function send(message) { if (!test.online) return false; test.sent = test.sent.concat([message]); return true }
  }
  FloatingWindow {
    visible: true; implicitWidth: 850; implicitHeight: 900
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "work"; instanceName: "delivery-test"; focused: true }
    TestEvent { id: input }
  }
  TestCase { id: gui; when: false }
  function check(value, message) { if (!value) throw new Error(message) }
  function event(message) { state.onLine(JSON.stringify(message), 0) }
  function history(text) {
    event({type:"response",command:"get_entries",session:"worker",data:{entries:[
      {type:"message",id:"confirmed",message:{role:"user",content:[{type:"text",text:text}]}}
    ]}})
  }
  function row(text) { return rail.groupedFeed.find(item => item.kind === "user" && item.text === text) }
  function find(item, text) {
    if (item.visible && item.text === text) return item
    for (var child of item.children || []) { var found = find(child,text); if (found) return found }
    return null
  }
  function click(text) {
    var item = find(rail,text); check(!!item,"missing visible control: " + text)
    gui.wait(30); input.mouseClick(item,5,item.height/2,Qt.LeftButton,Qt.NoModifier,0)
  }
  function reply(success) {
    var request = test.sent[test.sent.length - 1]
    event({type:"response",command:request.type,id:request.id,session:"worker",success:success,error:success ? "" : "Pi rejected this request"})
  }
  Timer {
    interval: 220; running: true; repeat: true
    onTriggered: {
      if (test.phase === 0) {
        if (!state.connected) return
        test.event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle"}]})
        rail.jumpToSession("worker"); test.history("Real history")
        test.online = false; state.submit("worker","Offline copy")
      } else if (test.phase === 1) {
        test.check(test.row("Offline copy").delivery === "failed","offline message lacks failed status")
        test.check(!!test.find(rail,"Not delivered"),"failure tag is not rendered")
        test.online = true; rail.prefillComposer("Next draft"); test.click("Resend")
      } else if (test.phase === 2) {
        test.check(test.sent.filter(item => item.message === "Offline copy").length === 1,"resend did not use the normal transport exactly once")
        test.check(test.row("Offline copy").delivery === "pending","resend retained failure status")
        test.reply(false)
      } else if (test.phase === 3) {
        test.check(state.feedFor("worker").some(item => item.text === "Offline copy" && item.delivery === "failed"),"Pi rejection did not mark the matching message failed")
        test.check(!!test.find(rail,"Not delivered"),"rejection tag was hidden while typing")
        test.check(state.feedFor("worker").some(item => String(item.text).indexOf("Pi rejected this request") >= 0),"rejection reason is missing")
        test.click("Delete")
      } else if (test.phase === 4) {
        test.check(!test.row("Offline copy"),"delete did not remove the local copy")
        test.check(rail.composerText === "Next draft","delete or resend disturbed the composer draft")
        rail.prefillComposer("")
        test.history("Real history")
        test.check(!test.row("Offline copy") && !!test.row("Real history"),"history refresh restored the deleted echo or deleted real history")
        test.event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"streaming"}]})
        state.submit("worker","Slow steer"); test.reply(true)
        test.event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle"}]})
        test.history("Real history")
      } else if (test.phase === 5) {
        test.check(test.row("Slow steer").delivery === "accepted","delayed accepted steer was mislabelled")
        test.check(!test.find(rail,"Resend"),"accepted message offers a duplicate resend")
        var count = test.sent.length; test.click("Delete")
        test.check(test.sent.length === count,"deleting a local copy touched the agent")
        test.history("Slow steer")
      } else if (test.phase === 6) {
        test.check(test.row("Slow steer") && !test.row("Slow steer").deliveryId,"later confirmed history was hidden or retained local controls")
        state.submit("worker","Daemon rejection")
        test.event({type:"error",session:"worker",error:"not delivered: worker is waiting on an unanswered question"})
      } else if (test.phase === 7) {
        test.check(test.row("Daemon rejection").delivery === "failed","explicit daemon rejection lacks failure tag")
        test.click("Delete")
        test.online = false; state.submit("worker",test.attachmentMessage)
      } else if (test.phase === 8) {
        test.online = true; test.click("Resend")
      } else if (test.phase === 9) {
        test.check(test.sent.filter(item => item.message === test.attachmentMessage).length === 1,"resend altered or duplicated attachment references or selected code")
        console.log("PASS: not-delivered tag, delete and resend clicks; attachment and selected-code preservation, Pi and daemon rejections, delayed acceptance, confirmed history and agent isolation")
        Qt.quit()
      }
      test.phase++
    }
  }
}

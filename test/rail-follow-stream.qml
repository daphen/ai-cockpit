import QtQuick
import QtTest
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  property string opened: ""
  AgentdState { id: state; selectedSession: rail.selectedRaw; function send(message) { return true } }
  FloatingWindow {
    visible: true; width: 720; height: 700
    Rail {
      id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "follow-glide-test"; focused: true
      onRequestFocus: forceActiveFocus()
      function openFileRef(path) { test.opened = String(path) }
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
  function named(prefix) { return find(rail,item => String(item.objectName || "").indexOf(prefix) === 0) }
  function key(k, m) { gui.wait(20); input.keyClick(k, m || Qt.NoModifier, 0) }
  function event(message) { state.onLine(JSON.stringify(Object.assign({session:"worker"},message)),0) }
  property var ys: []
  property real startY: 0
  function view() { return find(rail, i => i.objectName === "feedView" || (i.model !== undefined && i.contentY !== undefined && i.count > 30)) }
  function msgs(n) {
    var e = [], parent = null
    for (var k = 0; k < n; k++) { e.push({type:"message",id:"m"+k,parentId:parent,message:{role:k%2?"assistant":"user",content:[{type:"text",text:"Message number " + k + " with a little text"}]}}); parent = "m"+k }
    return {type:"response",command:"get_entries",data:{leafId:parent,entries:e}}
  }
  Timer { interval: 16; repeat: true; running: test.phase >= 4; onTriggered: { var v = test.view(); if (v) test.ys.push(v.contentY) } }
  property int lagged: 0
  property int samples: 0
  property string longReply: ""
  function update(ev) { event({type:"message_update", message:{role:"assistant", model:"m"}, assistantMessageEvent: ev}) }
  Timer {
    interval: 40; repeat: true; running: test.phase >= 4 && test.phase < 9
    onTriggered: {
      update({type:"text_delta", contentIndex:0, delta:"More streamed words land here and wrap onto new lines. "})
      var v = test.view(); if (!v) return
      test.samples++
      if (v.originY + v.contentHeight - v.height - v.contentY > 120) test.lagged++
    }
  }
  Timer {
    interval: 500; repeat: true; running: true
    onTriggered: {
      var p = phase++
      if (p === 0) {
        event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"streaming"}]})
        rail.jumpToSession("worker")
        event(msgs(40))
      } else if (p === 3) {
        event({type:"agent_start"}); event({type:"message_start", message:{role:"assistant",content:[]}})
        update({type:"text_start", contentIndex:0})
      } else if (p === 16) {
        var v = view(), end = v.originY + v.contentHeight - v.height
        check(samples > 40, "setup: too few samples " + samples)
        check(lagged <= 2, "the rail fell behind a long stream: " + lagged + " of " + samples + " samples were over 120px from the bottom")
        check(Math.abs(v.contentY - end) < 2, "after streaming the rail should sit at the bottom, is " + (end - v.contentY) + "px short")
        console.log("PASS: the rail keeps up with a long stream (" + lagged + "/" + samples + " lagging samples)")
        Qt.quit()
      }
    }
  }
}

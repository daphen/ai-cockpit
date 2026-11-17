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
  Timer {
    interval: 400; repeat: true; running: true
    onTriggered: {
      var p = phase++
      if (p === 0) {
        event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle"}]})
        rail.jumpToSession("worker")
        event(msgs(40))
      } else if (p === 3) {
        var v = view(); check(v, "no feed view")
        startY = v.contentY
        check(Math.abs(v.contentY - (v.originY + v.contentHeight - v.height)) < 1, "setup: should start at the bottom")
        event(msgs(42))
      } else if (p === 5) {
        var v = view(), end = v.originY + v.contentHeight - v.height
        check(end > startY + 40, "setup: new messages should grow the feed, grew " + (end - startY))
        check(Math.abs(v.contentY - end) < 1, "after the glide the rail should sit at the bottom, is " + (end - v.contentY) + "px short")
        var between = ys.filter(y => y > startY + 2 && y < end - 2).length
        check(between >= 3, "new content should scroll in smoothly, saw " + between + " in-between frames")
        console.log("PASS: new content glides the rail to the bottom instead of jumping")
        Qt.quit()
      }
    }
  }
}

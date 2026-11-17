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
      id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "rail-half-test"; focused: true
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
  property int c0: 0
  Timer {
    interval: 400; repeat: true; running: true
    onTriggered: {
      if (phase === 0) {
        event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle"}]})
        rail.jumpToSession("worker")
        var entries = [], parent = null
        for (var n = 0; n < 40; n++) {
          entries.push({type:"message",id:"m"+n,parentId:parent,message:{role:n%2?"assistant":"user",content:[{type:"text",text:"Message number " + n + " with a little text"}]}})
          parent = "m"+n
        }
        event({type:"response",command:"get_entries",data:{leafId:parent,entries:entries}})
      } else if (phase === 1) {
        rail.exitInsert(); rail.forceActiveFocus()
        rail.cur = rail.navTotal - 1
      } else if (phase === 2) {
        c0 = rail.cur
        key(Qt.Key_U, Qt.ControlModifier)
      } else if (phase === 3) {
        check(rail.cur < c0 - 2, "ctrl-u should move up about half a screen, went " + c0 + " -> " + rail.cur)
        key(Qt.Key_D, Qt.ControlModifier)
      } else if (phase === 4) {
        check(rail.cur === c0, "ctrl-d should come back down, got " + rail.cur + " not " + c0)
        console.log("PASS: ctrl-u and ctrl-d move the rail cursor half a screen")
        Qt.quit()
      }
      phase++
    }
  }
}

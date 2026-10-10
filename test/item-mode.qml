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
    visible: true; width: 720; height: 1200
    Rail {
      id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "item-mode-test"; focused: true
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
  function key(k) { gui.wait(20); input.keyClick(k,Qt.NoModifier,0) }
  function event(message) { state.onLine(JSON.stringify(Object.assign({session:"worker"},message)),0) }
  readonly property string longOutput: Array.from({length: 30}, (_, row) => "line " + (row + 1)).join("\n")
  Timer {
    interval: 220; repeat: true; running: true
    onTriggered: {
      if (phase === 0) {
        event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle"}]})
        rail.jumpToSession("worker")
        event({type:"response",command:"get_entries",data:{leafId:"r2",entries:[
          {type:"message",id:"a",parentId:null,message:{role:"assistant",model:"gpt-6.1-sol",content:[
            {type:"text",text:"Did two things."},
            {type:"toolCall",id:"bash",name:"bash",arguments:{command:"seq 30"}},
            {type:"toolCall",id:"edit",name:"edit",arguments:{path:"/tmp/view.qml",edits:[{oldText:"a",newText:"b"}]}}
          ]}},
          {type:"message",id:"r1",parentId:"a",message:{role:"toolResult",toolCallId:"bash",toolName:"bash",content:[{type:"text",text:longOutput}]}},
          {type:"message",id:"r2",parentId:"r1",message:{role:"toolResult",toolCallId:"edit",toolName:"edit",content:[{type:"text",text:"Edited"}],
            details:{diff:"-1 old\n+1 new"}}}
        ]}})
      } else if (phase === 1) {
        rail.exitInsert(); rail.forceActiveFocus()
        rail.cur = rail.navTotal - 1
        key(Qt.Key_Return)
      } else if (phase === 2) {
        check(rail.itemMode && rail.itemFocus.endsWith("-tools"),"Enter did not focus the first item: " + rail.itemFocus)
        var header = find(rail,item => String(item.text || "").indexOf("Work details") === 0)
        check(header && header.width > 40,"focused header lost its text width")
        key(Qt.Key_J)
      } else if (phase === 3) {
        check(rail.itemFocus === "tool:worker:bash","j did not reach the command row: " + rail.itemFocus)
        var command = find(rail,item => String(item.text || "").indexOf("seq 30") === 0)
        check(command && command.width > 40,"focused command row lost its text width: " + (command && command.width))
        key(Qt.Key_Return)
      } else if (phase === 4) {
        check(named("tool-output:bash") && named("tool-output:bash").text.indexOf("line 21") === 0,"Enter did not open the command output")
        key(Qt.Key_J)
      } else if (phase === 5) {
        check(rail.itemFocus === "tool:worker:bash:all","j did not reach show all: " + rail.itemFocus)
        key(Qt.Key_Return)
      } else if (phase === 6) {
        check(named("tool-output:bash").text.indexOf("line 1\n") === 0,"show all did not expand from the keyboard")
        key(Qt.Key_J)
      } else if (phase === 7) {
        check(rail.itemFocus === "copyout:tool:worker:bash","copy buttons unreachable: " + rail.itemFocus)
        key(Qt.Key_L)
      } else if (phase === 8) {
        check(rail.itemFocus === "copycmd:tool:worker:bash","l did not move across the button row: " + rail.itemFocus)
        key(Qt.Key_J)
      } else if (phase === 9) {
        check(rail.itemFocus.indexOf("open:") === 0,"edit row unreachable: " + rail.itemFocus)
        key(Qt.Key_L)
      } else if (phase === 10) {
        check(rail.itemFocus === "tool:worker:edit","l did not reach the diff toggle: " + rail.itemFocus)
        key(Qt.Key_Return)
      } else if (phase === 11) {
        check(named("edit-diff:/tmp/view.qml"),"Enter on the toggle did not open the diff")
        key(Qt.Key_H)
      } else if (phase === 12) {
        key(Qt.Key_Return)
      } else if (phase === 13) {
        check(test.opened === "/tmp/view.qml","Enter on the file did not open it")
        key(Qt.Key_Escape)
      } else if (phase === 14) {
        check(!rail.itemMode,"Esc did not leave item mode")
        console.log("PASS: Enter enters item mode; hjkl walks headers, rows, show all, buttons, file and diff; Enter triggers; Esc leaves")
        Qt.quit()
      }
      phase++
    }
  }
}

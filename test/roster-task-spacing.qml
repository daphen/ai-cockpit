import QtQuick
import Quickshell
import QsLib
import "."
ShellRoot {
  id: test
  property int phase: 0
  property real compactHeight: 0
  AgentdState {
    id: state
    selectedSession: rail.selectedRaw
    function send(message) { return true }
  }
  FloatingWindow {
    visible: true; width: 720; height: 800
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "roster-task-spacing-test"; focused: true }
  }
  function find(item, name) {
    if (item.objectName === name) return item
    for (var child of item.children || []) { var hit = find(child, name); if (hit) return hit }
    return null
  }
  function check(value, message) { if (!value) throw new Error(message) }
  function history(task) {
    var entries = task ? [{type:"custom",customType:"cockpit-session-task",id:"task",parentId:null,data:{action:"switch",title:"Toggle inbox and picker keybinds"}}] : []
    state.onLine(JSON.stringify({type:"response",command:"get_entries",session:"quickshell",data:{entries:entries}}),0)
  }
  Timer {
    interval: 500; repeat: true; running: true
    onTriggered: {
      var label = test.find(rail, "activeTaskLabel")
      var rows = test.find(rail, "sessionRosterRows")
      if (test.phase === 0) {
        state.onLine(JSON.stringify({type:"roster",sessions:[{name:"quickshell",cwd:"/tmp",status:"idle"},{name:"ai-cockpit",cwd:"/tmp",status:"idle"}]}),0)
        rail.jumpToSession("quickshell"); rail.rosterOverride = true
        test.history(false)
      } else if (test.phase === 1) {
        test.check(!label.visible && Math.abs(rows.y - label.parent.y - label.parent.height - 4) < 0.1, "ordinary header spacing changed")
        test.compactHeight = rows.parent.height
        test.history(true)
      } else if (test.phase === 2) {
        test.check(label.visible && rail.activeTask.length > 0, "task subtitle missing")
        var subtitleBottom = label.mapToItem(rows.parent, 0, label.height).y
        test.check(rows.mapToItem(rows.parent, 0, 0).y - subtitleBottom >= 6, "task subtitle crowds the first roster row")
        test.check(Math.abs(rows.parent.height - test.compactHeight - 8) < 0.1, "sheet did not grow with the extra gap")
        rail.rosterOverride = false
      } else if (test.phase === 3) {
        test.check(Math.abs(rows.parent.height - label.parent.height - 8) < 0.1, "collapsed roster retained expanded gap")
        rail.rosterOverride = true; test.history(false)
      } else if (test.phase === 4) {
        test.check(!label.visible && Math.abs(rows.parent.height - test.compactHeight) < 0.1, "removing task did not restore compact spacing")
        console.log("PASS: task header adds 8px of roster spacing, sheet grows with it, no-task and collapsed geometry remain unchanged")
        Qt.quit()
      }
      test.phase++
    }
  }
}

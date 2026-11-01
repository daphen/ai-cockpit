import QtQuick
import QtTest
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  property var rails: [personal, work]
  AgentdState { id: state; scope: "personal"; selectedSession: personal.selectedRaw; function send(message) { return true } }
  AgentdState { id: workState; scope: "work"; selectedSession: work.selectedRaw; function send(message) { return true } }
  FloatingWindow {
    visible: true; width: 1400; height: 900
    Rail { id: personal; width: 700; height: parent.height; agentd: state; scopeMode: "personal"; instanceName: "personal"; focused: true; TestEvent { id: input } }
    Rail { id: work; x: 700; width: 700; height: parent.height; agentd: workState; scopeMode: "work"; instanceName: "work"; focused: true }
  }
  function check(value, message) { if (!value) throw new Error(message) }
  function find(item, predicate) {
    if (!item || item.visible === false) return null
    if (predicate(item)) return item
    for (var child of item.children || []) { var found = find(child, predicate); if (found) return found }
    return null
  }
  function frame(rail) { return find(rail, item => item.objectName === "composerFrame") }
  function composer(rail) { return find(frame(rail), item => item.cursorRectangle !== undefined && item.textDocument && !item.readOnly) }
  function flick(rail) { return find(frame(rail), item => item.contentY !== undefined && item.flickableDirection !== undefined) }
  Timer {
    interval: 250; repeat: true; running: true
    onTriggered: {
      var rail = test.rails[Math.floor(test.phase / 2) % 2]
      if (test.phase === 0) {
        for (var s of [state, workState])
          s.onLine(JSON.stringify({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle"}]}),0)
        personal.jumpToSession("worker"); work.jumpToSession("worker")
      }
      if (test.phase === 0 || test.phase === 2) {
        var field = composer(rail)
        check(!!field, "composer missing")
        field.forceActiveFocus()
        input.keyClick(Qt.Key_A, Qt.NoModifier, 0)
        input.keyClick(Qt.Key_Return, Qt.ShiftModifier, 0)
        input.keyClick(Qt.Key_B, Qt.NoModifier, 0)
        for (var k of [Qt.Key_C, Qt.Key_D, Qt.Key_E]) { input.keyClick(Qt.Key_Return, Qt.ShiftModifier, 0); input.keyClick(k, Qt.NoModifier, 0) }
        for (var i = 0; i < 6; i++) input.keyClick(Qt.Key_Backspace, Qt.NoModifier, 0)
      } else if (test.phase === 1 || test.phase === 3) {
        var f = composer(rail), fl = flick(rail)
        check(f.text === "a\nb", rail.instanceName + " composer text: " + JSON.stringify(f.text))
        check(fl.height >= f.contentHeight - 1, rail.instanceName + " composer did not grow: " + fl.height + " < " + f.contentHeight)
        check(fl.contentY === 0, rail.instanceName + " two lines scrolled the first out of view: contentY=" + fl.contentY)
        if (test.phase === 3) { console.log("PASS: two-line composer shows both lines in private and work"); Qt.quit() }
      }
      test.phase++
    }
  }
}

import QtQuick
import Quickshell
import "."

ShellRoot {
  id: test
  property var widths: [900, 650, 480, 360, 256]
  property int step: 0
  AgentdState { id: state; selectedSession: rail.selectedRaw }
  FloatingWindow {
    id: win
    visible: true; width: 900; height: 600
    Rail { id: rail; width: test.widths[test.step]; height: parent.height; agentd: state; scopeMode: "personal"; focused: true }
  }
  function find(item, name) {
    if (item.objectName === name) return item
    for (var child of item.children || []) { var hit = find(child, name); if (hit) return hit }
    return null
  }
  Timer {
    interval: 350; repeat: true; running: true
    onTriggered: {
      if (test.step === 0) {
        state.onLine(JSON.stringify({type:"roster",sessions:[{id:"root",name:"root",cwd:"/tmp",status:"streaming",model:"openai/gpt-6-sol"}]}), 0)
        rail.jumpToSession("root")
        rail.enterInsert()
      }
      var col = test.find(rail, "chinContent"), input = test.find(rail, "composerFrame"), hints = test.find(rail, "composerHints")
      if (!col || !input || !hints) throw new Error("chin items missing")
      var right = input.mapToItem(rail, input.width, 0).x
      var hintMax = 0
      for (var child of hints.children || []) {
        if (!child.visible || !child.width) continue
        hintMax = Math.max(hintMax, child.mapToItem(rail, child.width, 0).x)
      }
      if (input.width < 80 || right > rail.width - 20 || hintMax > rail.width - 20)
        throw new Error("composer or controls escape narrow rail at " + rail.width + ": composer right " + right + ", hints right " + hintMax)
      var top = input.mapToItem(rail, 0, 0).y
      if (top < 0 || top + input.height > rail.height - 20)
        throw new Error("composer escapes vertically at " + rail.width + "×" + rail.height)
      test.step++
      if (test.step === test.widths.length) { console.log("PASS: composer and controls fit narrow rail widths"); Qt.quit(); return }
      if (test.step >= 3) win.height = 400
    }
  }
}

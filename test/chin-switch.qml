import QtQuick
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  property real widthBefore: 0
  function fail(msg) { console.log("FAIL: " + msg); Qt.exit(1) }
  function pathCell() {
    function find(item) {
      if (item.objectName === "editorPath") return item
      for (var i = 0; i < item.children.length; i++) { var r = find(item.children[i]); if (r) return r }
      return null
    }
    return find(chin)
  }
  FloatingWindow { visible: true; width: 900; height: 40
    Chin { id: chin; anchors.fill: parent }
  }
  Timer { interval: 400; repeat: true; running: true
    onTriggered: {
      var cell = test.pathCell(), content = cell.parent.parent
      if (test.phase === 0) {
        chin.st = { path: "a.txt" }
      } else if (test.phase === 1) {
        test.widthBefore = cell.width
        chin.switching = true
      } else if (test.phase === 2) {
        if (content.opacity > 0.01) test.fail("chin contents still visible mid-switch: " + content.opacity)
        chin.st = { path: "apps/webapp/app/components/runs/v3/diagnosis/RunSheet.tsx" }
        Qt.callLater(function() {
          if (cell.width <= test.widthBefore + 100) test.fail("value change animated during a switch (width " + cell.width + ")")
        })
      } else if (test.phase === 3) {
        chin.switching = false
      } else if (test.phase === 4) {
        if (content.opacity < 0.99) test.fail("chin did not fade back in: " + content.opacity)
        var w = cell.width
        chin.st = { path: "b.txt" }
        Qt.callLater(function() {
          if (Math.abs(cell.width - w) > 1) test.fail("in-session change no longer animates (jumped to " + cell.width + ")")
        })
      } else {
        console.log("PASS: chin fades during a session switch, swaps values unseen, animates in-session changes")
        Qt.quit()
      }
      test.phase++
    }
  }
}

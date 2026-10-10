import QtQuick
import QtTest
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  readonly property string longPath: "/home/daphen/nixos.candidate-canvas-zoom-performance/experiments/hyprland-canvas/regression-archive/zoom-pinned-buffers/README.md"
  function find(item, predicate) {
    if (predicate(item)) return item
    for (var child of item.children || []) {
      var found = find(child, predicate)
      if (found) return found
    }
    return null
  }
  function check(value, message) { if (!value) throw new Error(message) }
  FloatingWindow {
    id: window
    visible: true; width: 1000; height: 100
    Chin { id: chin; anchors.fill: parent }
    TestEvent { id: input }
  }
  Timer {
    interval: 350; running: true; repeat: true
    onTriggered: {
      if (test.phase === 0) {
        chin.st = {path: test.longPath, ft: "markdown", add: 2735, del: 13, err: 2, warn: 1, search: "3/24"}
      } else {
        var path = test.find(chin, item => item.objectName === "editorPath")
        var text = test.find(path, item => item.text === test.longPath && item.opacity > 0)
        var ft = test.find(chin, item => item.text === "markdown")
        test.check(text && text.truncated && text.elide === Text.ElideMiddle, "long editor path is not elided: " + [path.width, text && text.width, text && text.implicitWidth, text && text.truncated, text && text.elide].join(","))
        test.check(path.width <= chin.width / 2, "editor path dominates the statusline")
        test.check(path.mapToItem(chin, path.width, 0).x < ft.mapToItem(chin, 0, 0).x, "editor path overlaps metadata")
        test.check(path.value === test.longPath, "full editor path was discarded")
        if (test.phase === 1) window.width = 550
        else if (test.phase === 2) input.mouseMove(path, 5, path.height / 2, 0, Qt.NoButton, Qt.NoModifier)
        else if (test.phase === 4) {
          var tooltip = test.find(chin.Window.window.contentItem, item => item.text === test.longPath && item.truncated === false && item.visible)
          test.check(tooltip, "full editor path is not available on hover")
          console.log("PASS: long editor paths elide without overlapping metadata and expose the full path on hover")
          Qt.quit()
        }
      }
      test.phase++
    }
  }
}

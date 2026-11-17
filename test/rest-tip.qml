import QtQuick
import QtTest
import Quickshell
import "."
import "PointerRest.js" as PointerRest
ShellRoot {
  id: test
  property int phase: 0
  FloatingWindow {
    visible: true; width: 400; height: 300
    Item {
      id: page; anchors.fill: parent
      HoverHandler { onPointChanged: PointerRest.report(point.scenePosition) }
      Rectangle {
        id: target; x: 0; y: 200; width: 400; height: 40
        HoverHandler { id: hover }
        RestTip { id: tip; parent: page; handler: hover; text: "the original ask"; delay: 300 }
      }
      TestEvent { id: input }
    }
  }
  function fail(m) { console.error("Error: " + m); Qt.exit(1) }
  Timer {
    interval: 500; repeat: true; running: true
    onTriggered: {
      if (phase === 0) input.mouseMove(page, 200, 80, -1, Qt.NoButton, Qt.NoModifier)
      else if (phase === 1) target.y = 60
      else if (phase === 3) {
        if (!hover.hovered) { fail("setup: the target should now be under the pointer"); return }
        if (tip.shown) { fail("a row scrolled under a still pointer should not show its tip"); return }
        input.mouseMove(page, 210, 82, -1, Qt.NoButton, Qt.NoModifier)
      } else if (phase === 4) {
        if (!tip.shown) { fail("moving onto the target and resting should show the tip"); return }
        input.mouseMove(page, 220, 84, -1, Qt.NoButton, Qt.NoModifier)
        if (tip.shown) { fail("moving should hide the tip until the pointer rests again"); return }
      } else if (phase === 5) {
        if (!tip.shown) { fail("resting again should bring the tip back"); return }
        target.y = 200
      } else if (phase === 6) {
        if (tip.shown) { fail("the tip should go when its target leaves the pointer"); return }
        console.log("PASS: tips need the pointer moved then rested; scrolling under a still pointer shows none")
        Qt.quit()
      }
      phase++
    }
  }
}

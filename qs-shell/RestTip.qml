import QtQuick
import QsLib
import "PointerRest.js" as PointerRest

// A tooltip that appears only after the pointer is moved onto its target and then rests;
// keyboard scrolling under a still pointer never shows it.
Rectangle {
  id: tip
  property HoverHandler handler
  property string text: ""
  property bool above: false
  property int delay: 600
  property real _enteredAt: 0
  property bool shown: false
  visible: opacity > 0
  opacity: shown ? 1 : 0
  Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
  z: 1000
  width: Math.min(label.implicitWidth + 24, 520)
  height: label.implicitHeight + 14
  radius: 8
  color: Theme.mode === "dark" ? "#0F0F0F" : "#FFFFFF"
  border { width: 1; color: Theme.hairline }

  function place() {
    if (!parent || !handler) return
    var p = handler.target.mapToItem(parent, handler.point.position.x, handler.point.position.y)
    x = Math.max(4, Math.min(parent.width - width - 4, p.x - 12))
    y = above || p.y + 20 + height > parent.height ? p.y - height - 12 : p.y + 20
  }
  Timer {
    id: rest
    interval: tip.delay
    onTriggered: {
      if (!tip.handler || !tip.handler.hovered || PointerRest.movedAt < tip._enteredAt - 100) return
      var still = Date.now() - PointerRest.movedAt
      if (still < tip.delay - 20) { interval = tip.delay - still; start(); return }
      interval = tip.delay
      tip.place(); tip.shown = tip.text !== ""
    }
  }
  Connections {
    target: tip.handler
    function onHoveredChanged() {
      tip.shown = false
      if (tip.handler.hovered) { tip._enteredAt = Date.now(); rest.restart() } else rest.stop()
    }
    function onPointChanged() {
      if (!tip.handler.hovered) return
      PointerRest.report(tip.handler.point.scenePosition)
      if (Date.now() - PointerRest.movedAt < 5) { tip.shown = false; rest.restart() }
    }
  }
  Text {
    id: label
    x: 12; y: 7
    width: Math.min(implicitWidth, 520 - 24)
    text: tip.text
    textFormat: Text.PlainText; wrapMode: Text.Wrap
    color: Theme.fg
    font { family: Theme.fontFamily; pixelSize: Theme.fontSize; weight: Theme.fontWeight }
  }
}

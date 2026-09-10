import QtQuick
import QsLib

Item {
  id: timeline
  property var segments: []
  property int selectedRow: -1
  signal jumpRequested(int row)
  implicitWidth: 32
  readonly property real pitch: Math.min(8, height / Math.max(1, segments.length))

  function activate(index) {
    if (index >= 0 && index < segments.length) jumpRequested(segments[index].row)
  }

  Repeater {
    model: timeline.segments.length
    Item {
      id: mark
      required property int index
      readonly property var segment: timeline.segments[index]
      width: timeline.width
      y: (timeline.height - timeline.segments.length * timeline.pitch) / 2 + index * timeline.pitch
      height: timeline.pitch
      readonly property bool selected: !!segment && timeline.selectedRow >= segment.row && timeline.selectedRow <= segment.end
      Behavior on y { NumberAnimation { duration: 110; easing.type: Easing.OutBack; easing.overshoot: 0.7 } }
      Rectangle {
        objectName: "taskNotch-" + mark.index
        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
        width: mark.segment?.active ? 28 : (hover.hovered || mark.selected ? 21 : 17)
        height: mark.segment?.active ? 3 : 2
        radius: height / 2
        color: mark.segment?.active ? Theme.cursor : (hover.hovered || mark.selected ? Theme.fg : Theme.dimmedFg)
        Behavior on width { NumberAnimation { duration: 110; easing.type: Easing.OutBack; easing.overshoot: 0.7 } }
        Behavior on height { NumberAnimation { duration: 110; easing.type: Easing.OutBack; easing.overshoot: 0.7 } }
        Behavior on color { ColorAnimation { duration: 110 } }
      }
      HoverHandler { id: hover }
      TapHandler { onTapped: timeline.activate(mark.index) }
      Rectangle {
        id: detailCard
        objectName: "taskDetail-" + mark.index
        readonly property real restingY: Math.min(0, timeline.height - mark.y - height)
        visible: opacity > 0.01
        opacity: hover.hovered ? 1 : 0
        anchors { right: parent.left; rightMargin: 6 }
        y: restingY + (hover.hovered ? 2 : -3)
        width: 230
        height: detail.implicitHeight + 16
        color: Theme.bg
        border.color: Theme.hairline
        radius: Theme.radiusSm
        Behavior on opacity {
          NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
        }
        Behavior on y {
          NumberAnimation {
            duration: Motion.med
            easing.type: Motion.easeEmphasized
            easing.bezierCurve: Motion.curveEmphasized
          }
        }
        Text {
          id: detail
          anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8 }
          text: (mark.segment?.title || "")
            + (mark.segment?.timestamp ? "\n" + Qt.formatDateTime(new Date(mark.segment.timestamp), "ddd hh:mm") : "")
            + (mark.segment?.finishedAt ? "\nFinished" : "")
            + (mark.segment?.outcome ? " — " + mark.segment.outcome : "")
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          color: Theme.fg
          font.family: Theme.fontFamily
          font.pixelSize: Theme.fontSize - 2
        }
      }
    }
  }
}

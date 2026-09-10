import QtQuick
import QsLib

Item {
  id: timeline
  property var segments: []
  signal jumpRequested(int row)
  implicitWidth: 14

  function activate(index) {
    if (index >= 0 && index < segments.length) jumpRequested(segments[index].row)
  }

  Repeater {
    model: timeline.segments
    Item {
      id: mark
      required property var modelData
      required property int index
      width: timeline.width
      y: modelData.position * Math.max(0, timeline.height - 14)
      height: Math.max(10, modelData.span * Math.max(0, timeline.height - 14))
      Rectangle {
        anchors { top: parent.top; bottom: parent.bottom; horizontalCenter: parent.horizontalCenter }
        width: hover.hovered ? 6 : 3
        radius: 2
        color: mark.modelData.active ? Theme.sky : Theme.fg_muted
        opacity: hover.hovered || mark.modelData.active ? 1 : 0.55
      }
      HoverHandler { id: hover }
      TapHandler { onTapped: timeline.activate(mark.index) }
      Rectangle {
        visible: hover.hovered
        anchors { right: parent.left; rightMargin: 6 }
        y: Math.min(0, timeline.height - mark.y - height)
        width: 230
        height: detail.implicitHeight + 16
        color: Theme.bg
        border.color: Theme.hairline
        radius: Theme.radiusSm
        Text {
          id: detail
          anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8 }
          text: mark.modelData.title
            + (mark.modelData.timestamp ? "\n" + Qt.formatDateTime(new Date(mark.modelData.timestamp), "ddd hh:mm") : "")
            + (mark.modelData.finishedAt ? "\nFinished" : "")
            + (mark.modelData.outcome ? " — " + mark.modelData.outcome : "")
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

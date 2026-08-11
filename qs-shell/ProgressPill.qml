import QtQuick
import QsLib

// Small "6/6" style task-progress pill.
Rectangle {
  property string value: ""
  visible: value !== ""
  implicitWidth: row.implicitWidth + 14
  implicitHeight: 18
  radius: 9
  color: Theme.surface2
  Row {
    id: row
    anchors.centerIn: parent
    spacing: 4
    Text { text: ""; color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: 10 }
    Text { text: value; color: Theme.fg_secondary; font.family: Theme.fontFamily; font.pixelSize: 10 }
  }
}

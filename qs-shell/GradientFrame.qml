import QtQuick
Rectangle {
  id: frame
  property color fill
  property color edge
  property real strength: 1
  Behavior on edge { ColorAnimation { duration: 140 } }
  Behavior on strength { NumberAnimation { duration: 140 } }
  gradient: Gradient {
    GradientStop { position: 0; color: Qt.alpha(frame.edge, 0.38 * frame.strength) }
    GradientStop { position: 0.5; color: Qt.alpha(frame.edge, 0.15 * frame.strength) }
    GradientStop { position: 1; color: Qt.alpha(frame.edge, 0.2 * frame.strength) }
  }
  Rectangle {
    anchors { fill: parent; margins: 1 }
    radius: Math.max(0, frame.radius - 1)
    color: frame.fill
  }
}

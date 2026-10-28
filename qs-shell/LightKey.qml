import QtQuick
// Light-mode raised face: the outline is a backing shape, so round ends match straight edges.
Rectangle {
  id: key
  property color outline
  property real ring: 1
  property color faceTop: "#FDFDFD"
  property color faceBottom: "#F3F3F4"
  property int fade: 0
  color: outline
  Behavior on color { enabled: key.fade > 0; ColorAnimation { duration: key.fade; easing.type: Easing.InOutQuad } }
  Rectangle {
    id: bevel
    anchors { fill: parent; margins: key.ring }
    radius: Math.max(0, key.radius - key.ring)
    color: "#FFFFFF"
    Rectangle {
      anchors { fill: parent; topMargin: 1 }
      radius: bevel.radius
      gradient: Gradient {
        GradientStop { position: 0; color: key.faceTop }
        GradientStop { position: 1; color: key.faceBottom }
      }
    }
  }
}

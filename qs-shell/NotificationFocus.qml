import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
  id: root
  required property bool active
  required property string session
  readonly property string viewed: active ? session : ""
  onViewedChanged: Qt.callLater(publish)
  Component.onCompleted: Qt.callLater(publish)

  property FileView marker: FileView {
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/agent-rail-focused"
    preload: false
    blockLoading: true
    blockAllReads: true
    blockWrites: true
    printErrors: false
  }

  function publish() {
    if (viewed) {
      marker.setText(Quickshell.processId + "\n" + viewed + "\n")
    } else {
      marker.reload()
      if (marker.text().split("\n")[0] === String(Quickshell.processId)) marker.setText("")
    }
  }
}

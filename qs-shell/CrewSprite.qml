import QtQuick
import Quickshell.Io

Item {
  id: crew
  property string profile: ""
  property string activity: "idle"
  property bool running: true
  readonly property string role: ({"lovable-orchestrator": "orchestrator", "lovable-reviewer": "reviewer", "lovable-watcher": "watcher"})[profile] || "worker"
  readonly property var tags: sheet.adapter.tags
  // Tool names without their own animation (e.g. "web_search") read as thinking.
  readonly property var range: tags[activity] || tags.thinking || [0, 0]
  property int frame: range[0]
  onRangeChanged: frame = range[0]

  FileView {
    id: sheet
    path: Qt.resolvedUrl("crew/" + crew.role + ".json").toString().replace(/^file:\/\//, "")
    adapter: JsonAdapter { property var tags: ({}) }
  }
  Timer {
    running: crew.running && crew.visible && crew.range[1] > crew.range[0]
    interval: (crew.activity === "idle" ? 1600 : 1000) / (crew.range[1] - crew.range[0] + 1)
    repeat: true
    onTriggered: crew.frame = crew.frame >= crew.range[1] ? crew.range[0] : crew.frame + 1
  }
  Image {
    anchors.fill: parent
    source: Qt.resolvedUrl("crew/" + crew.role + ".png")
    sourceClipRect: Qt.rect(crew.frame * 64, 0, 64, 64)
    smooth: false
  }
}

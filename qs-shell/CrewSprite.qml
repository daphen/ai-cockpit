import QtQuick
import Quickshell.Io

Item {
  id: crew
  property string profile: ""
  property string name: ""
  property string activity: "idle"
  property bool running: true
  readonly property int seed: { var h = 7; for (var i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) % 9973; return h }
  readonly property string role: ({ nixos: "orchestrator" })[name]
    || ({"lovable-orchestrator": "orchestrator", "lovable-reviewer": "reviewer", "lovable-watcher": "watcher"})[profile]
    || ["worker", "mopper", "watcher"][Math.floor(seed / 7) % 3]
  readonly property var loops: (manifest.adapter.loops || {})[role] || {}
  // Tool activities share the working loop; anything without a drawn loop (e.g. "web_search") reads as thinking.
  readonly property string pose: activity === "subagents" && loops.subagents ? "subagents"
    : ({ coding: "working", bash: "working", subagents: "working", stopping: "idle" })[activity] || activity
  readonly property real pace: 0.85 + (seed % 31) / 100
  readonly property var loop: loops[pose] || loops.thinking || { frames: ["a"], ms: [1000] }
  property int frame: 0
  onLoopChanged: frame = 0

  FileView {
    id: manifest
    path: Qt.resolvedUrl("crew/card/loops.json").toString().replace(/^file:\/\//, "")
    adapter: JsonAdapter { property var loops }
  }
  Timer {
    running: crew.running && crew.visible && crew.loop.frames.length > 1
    interval: crew.loop.ms[crew.frame % crew.loop.ms.length] * crew.pace
    repeat: true
    onTriggered: crew.frame = (crew.frame + 1) % crew.loop.frames.length
  }
  // All frames of the current loop stay decoded and only swap visibility.
  Repeater {
    model: crew.loop.frames
    Image {
      required property int index
      required property string modelData
      objectName: "crewFigure"
      anchors.fill: parent
      visible: crew.frame % crew.loop.frames.length === index
      source: "crew/card/" + crew.role + "-" + modelData + ".jpg"
      fillMode: Image.PreserveAspectCrop
      // Card art is replaced on disk while the Cockpit runs; a cached half-written decode would stay blank.
      cache: false
      verticalAlignment: Image.AlignVCenter
    }
  }
}

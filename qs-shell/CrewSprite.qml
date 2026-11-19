import QtQuick
import Quickshell.Io

Item {
  id: crew
  property string profile: ""
  property string name: ""
  property string activity: "idle"
  readonly property int seed: { var h = 7; for (var i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) % 9973; return h }
  readonly property string role: ({ nixos: "orchestrator" })[name]
    || ({"lovable-orchestrator": "orchestrator", "lovable-reviewer": "reviewer", "lovable-watcher": "watcher"})[profile]
    || ["worker", "mopper", "watcher"][Math.floor(seed / 7) % 3]
  readonly property var loops: (manifest.adapter.loops || {})[role] || {}
  // Tool activities share the working loop; anything without a drawn loop (e.g. "web_search") reads as thinking.
  readonly property string pose: activity === "subagents" && loops.subagents ? "subagents"
    : ({ coding: "working", bash: "working", subagents: "working", stopping: "idle" })[activity] || activity
  readonly property var loop: loops[pose] || loops.thinking || { frames: ["a"], ms: [1000] }

  FileView {
    id: manifest
    path: Qt.resolvedUrl("crew/card/loops.json").toString().replace(/^file:\/\//, "")
    adapter: JsonAdapter { property var loops; property int version: 0 }
  }
  // Still frames: animating decoded a full-size JPEG on the UI thread every swap, even behind a hidden Dashboard.
  // A synchronous load keeps the old pose up until the new one is decoded, so the panel is never empty.
  Image {
    objectName: "crewFigure"
    anchors.fill: parent
    asynchronous: false
    // The build stamps a version so a rebuilt frame never reuses an old cached decode.
    source: Qt.resolvedUrl("crew/card/" + crew.role + "-" + crew.loop.frames[0] + ".jpg") + "?v=" + manifest.adapter.version
    fillMode: Image.PreserveAspectCrop
    verticalAlignment: Image.AlignVCenter
  }
}

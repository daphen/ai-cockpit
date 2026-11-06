import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import QsLib

// Left-pane workbench for a spritecook project: everything it shows comes from preview/,
// which the spritecook CLI and its Aseprite extension rewrite after every change.
FocusScope {
  id: bench
  property string project: ""
  readonly property string previewDir: project + "/preview"
  readonly property var markColor: ({ stray: "#ff2d6f", double: "#ffc400", palette: "#00dcff", alpha: "#c800ff" })

  property var sprites: []
  property string selected: ""
  readonly property var current: sprites.find(s => s.name === selected) || sprites[0] || null
  property var sheet: ({ frames: [], meta: { frameTags: [] } })
  property var marks: []
  property string animation: ""
  property int frame: 0
  property bool playing: true
  property bool showMarks: true
  property string status: ""

  readonly property var frames: sheet.frames || []
  readonly property var tags: (sheet.meta && sheet.meta.frameTags) || []
  readonly property var range: {
    var tag = tags.find(t => t.name === animation)
    return tag ? [tag.from, tag.to] : [0, 0]
  }
  readonly property int frameW: frames.length ? frames[0].frame.w : 0
  readonly property int frameH: frames.length ? frames[0].frame.h : 0
  readonly property string sheetUrl: current ? "file://" + previewDir + "/" + current.name + ".png?v=" + current.stamp : ""
  readonly property var frameMarks: marks.filter(m => m.frame === frame)

  function rescan() {
    var out = []
    for (var i = 0; i < folder.count; i++)
      out.push({ name: String(folder.get(i, "fileName")).replace(/\.json$/, ""), stamp: Number(folder.get(i, "fileModified")) })
    sprites = out
  }
  function select(name) {
    selected = name
    animation = ""
    frame = 0
  }
  function step(delta) {
    playing = false
    var lo = range[0], hi = range[1]
    frame = lo + ((frame - lo + delta) % (hi - lo + 1) + (hi - lo + 1)) % (hi - lo + 1)
  }
  function pickAnimation(name) {
    animation = name
    frame = range[0]
    playing = name !== ""
  }
  function spriteFile() { return current ? project + "/" + current.name + ".aseprite" : "" }
  function run(args, label) {
    if (!current || action.running) return
    status = label + "…"
    action.command = ["spritecook"].concat(args)
    action.running = true
  }

  FolderListModel {
    id: folder
    folder: bench.project ? "file://" + bench.previewDir : ""
    nameFilters: ["*.json"]
    showDirs: false
    sortField: FolderListModel.Time
    onCountChanged: bench.rescan()
    onStatusChanged: if (status === FolderListModel.Ready) bench.rescan()
  }
  // Replacing a preview in place keeps the count, so also rescan on any row change.
  Connections { target: folder; function onDataChanged() { bench.rescan() } function onRowsInserted() { bench.rescan() } }

  FileView {
    path: bench.current ? bench.previewDir + "/" + bench.current.name + ".json" : ""
    property string stamp: bench.current ? String(bench.current.stamp) : ""
    onStampChanged: reload()
    printErrors: false
    onLoaded: {
      try { bench.sheet = JSON.parse(text()) } catch (e) { return }
      if (bench.animation && !bench.tags.some(t => t.name === bench.animation)) bench.animation = ""
      if (bench.frame >= bench.frames.length) bench.frame = bench.range[0]
    }
  }
  FileView {
    path: bench.current ? bench.previewDir + "/" + bench.current.name + ".lint" : ""
    property string stamp: bench.current ? String(bench.current.stamp) : ""
    onStampChanged: reload()
    printErrors: false
    onLoaded: { try { bench.marks = JSON.parse(text()) } catch (e) { bench.marks = [] } }
    onLoadFailed: bench.marks = []
  }
  FileView {
    id: projectFile
    path: bench.project ? bench.project + "/spritecook.json" : ""
    printErrors: false
    readonly property int size: { try { return JSON.parse(text()).size } catch (e) { return 0 } }
  }
  FileView {
    id: paletteFile
    path: bench.project ? bench.project + "/palette.gpl" : ""
    printErrors: false
    readonly property var colours: {
      var out = []
      String(text()).split("\n").forEach(function (line) {
        var m = line.match(/^\s*(\d+)\s+(\d+)\s+(\d+)/)
        if (m) out.push(Qt.rgba(m[1] / 255, m[2] / 255, m[3] / 255, 1))
      })
      return out
    }
  }
  Process {
    id: action
    stdout: StdioCollector { id: actionOut }
    stderr: StdioCollector { id: actionErr }
    onExited: code => {
      var lines = String(code === 0 ? actionOut.text : actionErr.text).trim().split("\n")
      bench.status = lines[lines.length - 1] || (code === 0 ? "done" : "failed")
    }
  }
  Timer {
    running: bench.playing && bench.visible && bench.range[1] > bench.range[0]
    repeat: true
    interval: bench.frames[bench.frame] ? Math.max(30, bench.frames[bench.frame].duration) : 100
    onTriggered: bench.frame = bench.frame >= bench.range[1] ? bench.range[0] : bench.frame + 1
  }

  Keys.onPressed: e => {
    var index = sprites.indexOf(current)
    if (e.key === Qt.Key_J || e.key === Qt.Key_Down) { if (index + 1 < sprites.length) select(sprites[index + 1].name) }
    else if (e.key === Qt.Key_K || e.key === Qt.Key_Up) { if (index > 0) select(sprites[index - 1].name) }
    else if (e.key === Qt.Key_L || e.key === Qt.Key_Right) step(1)
    else if (e.key === Qt.Key_H || e.key === Qt.Key_Left) step(-1)
    else if (e.key === Qt.Key_Space) playing = !playing
    else if (e.key === Qt.Key_0) pickAnimation("")
    else if (e.key >= Qt.Key_1 && e.key <= Qt.Key_9) { var tag = tags[e.key - Qt.Key_1]; if (tag) pickAnimation(tag.name) }
    else if (e.key === Qt.Key_M) showMarks = !showMarks
    else if (e.key === Qt.Key_O) { if (current) Quickshell.execDetached(["aseprite", spriteFile()]) }
    else if (e.key === Qt.Key_C) run(["lint", spriteFile()], "Checking pixels")
    else if (e.key === Qt.Key_E) run(["export", spriteFile()], "Exporting")
    else return
    e.accepted = true
  }

  component Tool: Rectangle {
    id: tool
    property string icon: ""
    property string label: ""
    property string key: ""
    property bool on: false
    signal clicked()
    implicitWidth: toolRow.implicitWidth + 20
    height: 32
    radius: 8
    color: on ? Theme.itemSelected : toolHover.hovered ? Theme.itemHover : Qt.alpha(Theme.fg, 0.06)
    Row {
      id: toolRow
      anchors.centerIn: parent
      spacing: 7
      Icon { name: tool.icon; width: 15; height: 15; color: Theme.fg; anchors.verticalCenter: parent.verticalCenter }
      Text { text: tool.label; color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
      Text { text: tool.key; color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter }
    }
    HoverHandler { id: toolHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: tool.clicked() }
  }

  Rectangle { anchors.fill: parent; color: Theme.bg }

  Column {
    id: list
    anchors { left: parent.left; top: parent.top; bottom: parent.bottom; margins: 14 }
    width: 190
    spacing: 6
    Text {
      text: bench.project.split("/").pop()
      color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: 15; font.weight: 600
    }
    Text {
      text: bench.sprites.length + " sprite" + (bench.sprites.length === 1 ? "" : "s")
      width: parent.width; wrapMode: Text.Wrap
      color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: 12
    }
    Item { width: 1; height: 6 }
    Repeater {
      model: bench.sprites
      Rectangle {
        required property var modelData
        width: list.width; height: 64; radius: 8
        color: bench.current && bench.current.name === modelData.name ? Theme.itemSelected : rowHover.hovered ? Theme.itemHover : "transparent"
        Rectangle {
          id: thumb
          x: 8; anchors.verticalCenter: parent.verticalCenter
          width: 48; height: 48; radius: 6; color: Theme.surface0
          Image {
            anchors.fill: parent; anchors.margins: 2
            source: "file://" + bench.previewDir + "/" + modelData.name + ".png?v=" + modelData.stamp
            sourceClipRect: Qt.rect(0, 0, projectFile.size, projectFile.size)
            fillMode: Image.PreserveAspectFit; smooth: false; cache: false
          }
        }
        Text {
          anchors { left: thumb.right; leftMargin: 10; right: parent.right; verticalCenter: parent.verticalCenter }
          text: modelData.name; elide: Text.ElideRight
          color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: 13
        }
        HoverHandler { id: rowHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: { bench.select(modelData.name); bench.forceActiveFocus() } }
      }
    }
  }

  Item {
    id: main
    anchors { left: list.right; right: parent.right; top: parent.top; bottom: parent.bottom; margins: 14 }

    Flow {
      id: tools
      width: parent.width
      visible: !!bench.current
      spacing: 6
      Tool { icon: "paintbrush"; label: "Open in Aseprite"; key: "o"; onClicked: if (bench.current) Quickshell.execDetached(["aseprite", bench.spriteFile()]) }
      Tool { icon: "magic-wand"; label: "Check pixels"; key: "c"; onClicked: bench.run(["lint", bench.spriteFile()], "Checking pixels") }
      Tool { icon: "eye-open"; label: "Marks"; key: "m"; on: bench.showMarks; onClicked: bench.showMarks = !bench.showMarks }
      Tool { icon: "square-dotted-arrow-bottom-right"; label: "Export sheet"; key: "e"; onClicked: bench.run(["export", bench.spriteFile()], "Exporting") }
    }

    Rectangle {
      id: stage
      anchors { top: tools.bottom; topMargin: 12; left: parent.left; right: parent.right; bottom: strip.top; bottomMargin: 12 }
      radius: 10
      color: Theme.mode === "light" ? "#d9dce3" : "#2b2f3a"
      Column {
        anchors.centerIn: parent
        visible: !bench.current
        spacing: 8
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "No sprites yet"
               color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: 15; font.weight: 600 }
        Text { anchors.horizontalCenter: parent.horizontalCenter; horizontalAlignment: Text.AlignHCenter
               text: "Describe a character in the chat, e.g.\n“draw a fox adventurer with a satchel, side view”"
               color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: 13 }
      }
      readonly property int scale: bench.frameW ? Math.max(1, Math.floor(Math.min((width - 40) / bench.frameW, (height - 40) / bench.frameH))) : 1
      Item {
        id: canvas
        anchors.centerIn: parent
        width: bench.frameW * stage.scale; height: bench.frameH * stage.scale
        Rectangle { anchors.fill: parent; color: "transparent"; border.color: Qt.alpha(Theme.fg, 0.12); border.width: 1 }
        Image {
          anchors.fill: parent
          visible: bench.frameW > 0
          source: bench.sheetUrl
          sourceClipRect: bench.frames[bench.frame] ? Qt.rect(bench.frames[bench.frame].frame.x, 0, bench.frameW, bench.frameH) : Qt.rect(0, 0, 0, 0)
          smooth: false; cache: false
        }
        Repeater {
          model: bench.showMarks ? bench.frameMarks : []
          Rectangle {
            required property var modelData
            x: modelData.x * stage.scale; y: modelData.y * stage.scale
            width: stage.scale; height: stage.scale
            color: Qt.alpha(bench.markColor[modelData.kind] || "#ffffff", 0.35)
            border.color: bench.markColor[modelData.kind] || "#ffffff"; border.width: Math.max(1, stage.scale / 6)
          }
        }
      }
      Text {
        anchors { left: parent.left; bottom: parent.bottom; margins: 10 }
        text: bench.frameW ? bench.frameW + "×" + bench.frameH + " · " + stage.scale + "× · frame " + (bench.frame + 1) + "/" + bench.frames.length
              + (bench.marks.length ? " · " + bench.frameMarks.length + " marks here, " + bench.marks.length + " total" : " · clean") : ""
        color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: 12
      }
      Text {
        anchors { right: parent.right; bottom: parent.bottom; margins: 10 }
        visible: bench.showMarks && bench.marks.length > 0
        text: [["stray", "stray"], ["double", "doubled corner"], ["palette", "off-palette"], ["alpha", "semi-transparent"]]
          .map(k => "<font color=\"" + bench.markColor[k[0]] + "\">■</font> " + k[1]).join("&nbsp;&nbsp;")
        textFormat: Text.StyledText
        color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: 12
      }
    }

    Column {
      id: strip
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
      spacing: 10
      Row {
        spacing: 6
        visible: !!bench.current
        Tool { icon: "image"; label: "Base"; key: "0"; on: bench.animation === ""; onClicked: bench.pickAnimation("") }
        Repeater {
          model: bench.tags
          Tool { required property var modelData; required property int index
                 icon: "film"; label: modelData.name; key: String(index + 1); on: bench.animation === modelData.name
                 onClicked: bench.pickAnimation(modelData.name) }
        }
        Tool { visible: bench.animation !== ""; icon: "half-dotted-circle-play"; label: bench.playing ? "Pause" : "Play"; key: "space"; onClicked: bench.playing = !bench.playing }
      }
      Row {
        spacing: 6
        visible: !!bench.current
        Repeater {
          model: bench.range[1] - bench.range[0] + 1
          Rectangle {
            required property int index
            readonly property int n: bench.range[0] + index
            width: 56; height: 56; radius: 6
            color: Theme.surface0
            border.color: bench.frame === n ? Theme.orange : "transparent"; border.width: 2
            Image {
              anchors.fill: parent; anchors.margins: 4
              source: bench.sheetUrl
              sourceClipRect: bench.frames[parent.n] ? Qt.rect(bench.frames[parent.n].frame.x, 0, bench.frameW, bench.frameH) : Qt.rect(0, 0, 0, 0)
              fillMode: Image.PreserveAspectFit; smooth: false; cache: false
            }
            TapHandler { onTapped: { bench.playing = false; bench.frame = parent.n; bench.forceActiveFocus() } }
          }
        }
      }
      Row {
        spacing: 2
        Repeater {
          model: paletteFile.colours
          Rectangle { required property color modelData; width: 18; height: 18; radius: 3; color: modelData }
        }
      }
      Text {
        visible: !!bench.current || !!bench.status
        text: bench.status || "j/k sprite · h/l frame · space play · 0–9 animation · o Aseprite · c check · e export · m marks"
        color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: 12
      }
    }
  }
}

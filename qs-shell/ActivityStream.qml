import QtQuick
import QsLib

Item {
  id: root
  property var agentd: null
  property var sessions: []
  property color muted: Theme.fg_muted
  property var activityLabelFor: sid => "idle"
  property var taskFor: sid => ""
  property string cursorKey: ""
  property bool focused: false
  signal sessionRequested(string sid)

  function base(path) { var s = String(path || ""); return s.slice(s.lastIndexOf("/") + 1) }
  function clock(at) { var d = new Date(at); return ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2) }
  function dayLabel(at) {
    var d = new Date(at), today = new Date()
    if (d.toDateString() === today.toDateString()) return "TODAY"
    if (d.toDateString() === new Date(today.getTime() - 86400000).toDateString()) return "YESTERDAY"
    return d.toLocaleDateString(Qt.locale(), "dddd d MMMM").toUpperCase()
  }

  readonly property var working: {
    if (!agentd) return []
    agentd.gen; agentd.pendingGen; agentd.curToolGen
    return sessions.filter(s => !s.offline && agentd.isBusy(s.name)).map(s => s.name)
  }
  // Edits fold per session until that session's next prompt, summary, task or ask.
  readonly property var rows: {
    if (!agentd) return []
    agentd.activityGen
    var src = agentd.activity.slice().sort((a, b) => b.at - a.at)
    var out = [], day = "", open = {}
    for (var r of src) {
      var label = dayLabel(r.at)
      if (label !== day) { out.push({ kind: "day", key: "day:" + label, text: label }); day = label; open = {} }
      if (r.kind === "edit") {
        var fold = open[r.sid]
        if (fold) {
          if (fold.files.indexOf(base(r.path)) < 0) fold.files.push(base(r.path))
          fold.add += r.add; fold.del += r.del
          continue
        }
        fold = Object.assign({}, r, { files: [base(r.path)] })
        open[r.sid] = fold
        out.push(fold)
        continue
      }
      delete open[r.sid]
      out.push(r)
    }
    return out
  }
  readonly property int cursor: {
    var i = rows.findIndex(r => r.key === cursorKey)
    return i >= 0 ? i : rows.findIndex(r => r.kind !== "day")
  }
  readonly property string currentSession: cursor >= 0 ? rows[cursor].sid : ""

  function move(delta) {
    for (var i = cursor + delta; i >= 0 && i < rows.length; i += delta)
      if (rows[i].kind !== "day") { cursorKey = rows[i].key; list.positionViewAtIndex(i, ListView.Contain); return }
  }
  function open() { if (currentSession) sessionRequested(currentSession) }

  ListView {
    id: list
    anchors.fill: parent
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    model: root.rows
    spacing: 2
    ScrollFeel { flick: list }

    header: Column {
      width: list.width
      bottomPadding: root.working.length ? 18 : 0
      spacing: 4
      Text {
        visible: root.working.length > 0
        text: "NOW \u00b7 " + root.working.length
        color: root.muted
        font { family: Theme.fontFamily; pixelSize: 13; weight: 600; letterSpacing: 1 }
        bottomPadding: 4
      }
      Repeater {
        model: root.working
        delegate: Row {
          required property string modelData
          spacing: 12
          Text {
            width: 170; elide: Text.ElideRight
            text: modelData; textFormat: Text.PlainText
            color: Theme.fg
            font { family: Theme.fontFamily; pixelSize: 15; weight: 600 }
          }
          Text {
            width: list.width - 182; elide: Text.ElideRight
            text: {
              root.agentd.curToolGen
              var edit = root.agentd.lastEditFor(modelData)
              return root.activityLabelFor(modelData) + (edit ? " \u00b7 " + root.base(edit) : "")
                + (root.taskFor(modelData) ? " \u00b7 " + root.taskFor(modelData) : "")
            }
            textFormat: Text.PlainText
            color: Theme.electric
            font { family: Theme.fontFamily; pixelSize: 15 }
          }
        }
      }
    }

    delegate: Item {
      id: row
      required property var modelData
      required property int index
      readonly property bool day: modelData.kind === "day"
      readonly property bool current: index === root.cursor && root.focused
      width: list.width
      height: day ? 40 : Math.max(26, body.implicitHeight + 8)

      Text {
        visible: row.day
        anchors.bottom: parent.bottom; anchors.bottomMargin: 6
        text: row.modelData.text || ""
        color: root.muted
        font { family: Theme.fontFamily; pixelSize: 13; weight: 600; letterSpacing: 1 }
      }
      Rectangle {
        visible: !row.day
        anchors.fill: parent
        radius: 6
        color: row.current ? Theme.itemSelected : hover.hovered ? Theme.itemHover : "transparent"
      }
      Row {
        visible: !row.day
        x: 8; y: 4
        spacing: 12
        Text {
          width: 44
          text: root.clock(row.modelData.at)
          color: root.muted
          font { family: Theme.fontFamily; pixelSize: 14 }
        }
        Text {
          width: 160; elide: Text.ElideRight
          text: row.modelData.sid || ""; textFormat: Text.PlainText
          color: Theme.fg_secondary
          font { family: Theme.fontFamily; pixelSize: 14; weight: 600 }
        }
        Item {
          id: body
          width: row.width - 248
          implicitHeight: row.modelData.kind === "edit" ? editLine.implicitHeight : line.implicitHeight
          Text {
            id: line
            visible: row.modelData.kind !== "edit"
            width: parent.width
            wrapMode: Text.Wrap; maximumLineCount: row.modelData.kind === "summary" ? 4 : 2; elide: Text.ElideRight
            textFormat: Text.PlainText
            text: {
              var r = row.modelData
              if (r.kind === "summary") return "\u27e2 " + r.text
              if (r.kind === "prompt") return "\u2192 " + (r.from === "you" ? "you" : "\u21c4 " + r.from) + ": " + r.text
              if (r.kind === "task") return (r.action === "finish" ? "\u2713 finished " : "\u25b8 ") + r.text
              if (r.kind === "ask") return "? " + r.text
              return ""
            }
            color: row.modelData.kind === "summary" ? Theme.fg : row.modelData.kind === "ask" ? Theme.orange
              : row.modelData.kind === "task" ? Theme.sky : root.muted
            font { family: Theme.fontFamily; pixelSize: 15; weight: row.modelData.kind === "task" ? 600 : 400 }
          }
          Row {
            id: editLine
            visible: row.modelData.kind === "edit"
            spacing: 8
            Text {
              width: Math.min(implicitWidth, body.width - 110); elide: Text.ElideRight
              text: "\u270e " + (row.modelData.files || []).join(", "); textFormat: Text.PlainText
              color: Theme.fg_secondary
              font { family: Theme.fontFamily; pixelSize: 15 }
            }
            Text { text: "+" + (row.modelData.add || 0); color: Theme.green; font { family: Theme.fontFamily; pixelSize: 15 } }
            Text { text: "\u2212" + (row.modelData.del || 0); color: Theme.red; font { family: Theme.fontFamily; pixelSize: 15 } }
          }
        }
      }
      HoverHandler { id: hover; enabled: !row.day; cursorShape: Qt.PointingHandCursor }
      TapHandler { enabled: !row.day; onTapped: { root.cursorKey = row.modelData.key; root.open() } }
    }

    Text {
      visible: !root.rows.length && !root.working.length
      anchors.centerIn: parent
      text: "No activity yet"
      color: root.muted
      font { family: Theme.fontFamily; pixelSize: 16 }
    }
  }
}

import QtQuick
import QsLib

FocusScope {
  id: root
  property color color: Theme.bg
  property var agentd: null
  property var rail: null
  property var sessions: []
  property var activityLabelFor: sid => "idle"
  property string cursorKey: ""
  property bool caretHeld: false
  readonly property bool focused: activeFocus
  signal sessionRequested(string sid)
  signal fileRequested(string sid, string path, int line)
  signal focusRequested(string direction)

  function cursorPoint() {
    var item = cursor >= 0 ? list.itemAtIndex(cursor) : null
    return item ? item.mapToItem(root, 28, item.dotY) : null
  }
  readonly property var restPoint: { list.contentY; list.contentHeight; cursor; width; return activeFocus ? cursorPoint() : null }
  onVisibleChanged: if (visible) { if (agentd) agentd.loadActivityHistory(); Qt.callLater(scroller.toEnd) }
  FeedScroll { id: scroller; view: list; chatVisible: root.visible }

  Keys.onPressed: event => {
    var ctrl = event.modifiers & Qt.ControlModifier
    if (ctrl && event.key === Qt.Key_L) focusRequested("right")
    else if (ctrl && event.key === Qt.Key_H) focusRequested("left")
    else if (event.key === Qt.Key_J || event.key === Qt.Key_Down) move(1)
    else if (event.key === Qt.Key_K || event.key === Qt.Key_Up) move(-1)
    else if (event.key === Qt.Key_G) edge(event.modifiers & Qt.ShiftModifier)
    else if (event.key === Qt.Key_S) { if (currentRow) sessionRequested(currentRow.sid) }
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) open()
    else return
    event.accepted = true
  }
  Rectangle { anchors.fill: parent; color: root.color }
  TapHandler { onTapped: root.forceActiveFocus() }

  readonly property bool light: Theme.mode === "light"
  readonly property string bodyFont: rail ? rail.messageFontFamily : "Geist"
  readonly property int fsBody: rail ? rail.fsBody : Theme.fontSize + 3
  readonly property int fsName: rail ? rail.fsName : Theme.fontSize + 4
  readonly property int fsMeta: rail ? rail.fsMeta : Theme.fontSize + 2
  readonly property color contentColor: light ? "#23272B" : "#FAFAFA"
  readonly property color metaColor: light ? "#747D84" : "#909090"

  function clock(at) { var d = new Date(at); return ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2) }
  function dayLabel(at) {
    var d = new Date(at), today = new Date()
    if (d.toDateString() === today.toDateString()) return "Today"
    if (d.toDateString() === new Date(today.getTime() - 86400000).toDateString()) return "Yesterday"
    return d.toLocaleDateString(Qt.locale(), "dddd d MMMM")
  }
  function busy(sid) {
    if (!agentd) return false
    agentd.gen; agentd.pendingGen; agentd.curToolGen
    return agentd.isBusy(sid)
  }
  function relPath(sid, path) {
    var cwd = String((sessions.find(s => s.name === sid) || {}).cwd || "")
    var p = String(path || "")
    if (cwd && p.indexOf(cwd + "/") === 0) return p.slice(cwd.length + 1)
    return p.replace(/^\/home\/[^/]+/, "~")
  }

  readonly property var working: sessions.filter(s => busy(s.name)).map(s => s.name)
  // Only work that changed code is shown: one group per session task, one row per file.
  readonly property var groups: {
    if (!agentd) return []
    agentd.activityGen
    var src = agentd.activity.slice().sort((a, b) => a.at - b.at)
    var all = [], open = {}, task = {}, prompt = {}
    function close(sid) { delete open[sid] }
    for (var r of src) {
      var g = open[r.sid]
      if (g && r.at - g.end > 3 * 3600000) { close(r.sid); g = null }
      if (r.kind === "task") {
        if (r.action === "switch") { close(r.sid); task[r.sid] = r.text }
        else if (g && g.task === r.text) g.done = true
        continue
      }
      if (r.kind === "prompt") { if (g && g.summary && !g.task) close(r.sid); if (!open[r.sid]) prompt[r.sid] = r; continue }
      if (r.kind === "summary") { if (g) { g.summary = r.text; g.end = Math.max(g.end, r.at) } continue }
      if (r.kind !== "edit") continue
      if (!g) {
        var p = prompt[r.sid]
        g = { key: r.key, sid: r.sid, task: task[r.sid] || "", prompt: p ? p.text : "", from: p ? p.from : "", start: r.at, end: r.at, files: [], byPath: {}, summary: "", done: false }
        open[r.sid] = g
        all.push(g)
      }
      g.end = Math.max(g.end, r.at)
      var f = g.byPath[r.path]
      if (!f) { f = { path: r.path, add: 0, del: 0, edits: 0 }; g.byPath[r.path] = f; g.files.push(f) }
      f.add += r.add || 0; f.del += r.del || 0; f.edits++
      f.at = r.at; f.line = r.line || 1; f.diff = r.diff || []; if (r.why) f.why = r.why
    }
    return all.sort((a, b) => a.end - b.end).slice(-150)
  }
  readonly property var rows: {
    var out = [], day = ""
    for (var g of groups) {
      var label = dayLabel(g.end)
      if (label !== day) { out.push({ kind: "day", key: "day:" + label, text: label }); day = label }
      out.push({ kind: "head", key: "head:" + g.key, sid: g.sid, task: g.task, prompt: g.prompt, from: g.from, done: g.done, end: g.end, count: g.files.length })
      for (var f of g.files)
        out.push({ kind: "file", key: "file:" + g.key + ":" + f.path, sid: g.sid, path: f.path, add: f.add, del: f.del,
                   edits: f.edits, at: f.at, line: f.line, diff: f.diff, why: f.why || "" })
      if (g.summary) out.push({ kind: "result", key: "result:" + g.key, sid: g.sid, text: g.summary })
    }
    return out
  }
  // Updated in place so the view keeps its scroll position when rows arrive.
  onRowsChanged: {
    for (var i = 0; i < rows.length; i++) {
      var at = -1
      for (var j = i; j < rowModel.count; j++) if (rowModel.get(j).key === rows[i].key) { at = j; break }
      if (at < 0) rowModel.insert(i, { key: rows[i].key })
      else if (at > i) rowModel.move(at, i, 1)
    }
    if (rowModel.count > rows.length) rowModel.remove(rows.length, rowModel.count - rows.length)
    scroller.synced()
  }
  Component.onCompleted: rowsChanged()
  readonly property int cursor: {
    var i = rows.findIndex(r => r.key === cursorKey)
    if (i >= 0) return i
    for (i = rows.length - 1; i >= 0 && rows[i].kind !== "file"; i--);
    return i
  }
  readonly property var currentRow: cursor >= 0 ? rows[cursor] : null

  function select(i) {
    cursorKey = rows[i].key
    var last = rows.length - 1
    while (last > i && rows[last].kind !== "file") last--
    scroller.cursorMoved(i, i === last)
  }
  function move(delta) {
    for (var i = cursor + delta; i >= 0 && i < rows.length; i += delta)
      if (rows[i].kind === "file") { select(i); return }
  }
  function edge(last) {
    for (var n = 0; n < rows.length; n++) {
      var i = last ? rows.length - 1 - n : n
      if (rows[i].kind === "file") { select(i); return }
    }
  }
  function open() { if (currentRow) fileRequested(currentRow.sid, currentRow.path, currentRow.line || 1) }

  component Orb: ThinkingOrb {
    required property string sid
    readonly property var colors: root.rail ? root.rail.fleetActivityColors(sid) : []
    running: false
    activityColors: colors
    glow: colors.length ? colors[0] : "#999999"
    seedKey: sid
    idleBlur: 1
  }

  ListView {
    id: list
    width: Math.min(parent.width - 64, 1400)
    height: parent.height
    anchors.horizontalCenter: parent.horizontalCenter
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    model: ListModel { id: rowModel }
    cacheBuffer: 1000000
    ScrollFeel { flick: list; onScrolled: up => scroller.userScrolled(up) }
    onDraggingChanged: dragging ? scroller.gestureStarted() : scroller.gestureEnded()
    header: Item { height: 12 }

    footer: Flow {
      width: list.width
      spacing: 8
      topPadding: root.working.length ? 14 : 0
      bottomPadding: 24
      Repeater {
        model: root.working
        delegate: PillSurface {
          id: pill
          required property string modelData
          height: 30
          width: nowRow.implicitWidth + 24
          hovered: pillHover.hovered
          HoverHandler { id: pillHover; cursorShape: Qt.PointingHandCursor }
          TapHandler { onTapped: root.sessionRequested(pill.modelData) }
          Row {
            id: nowRow
            anchors.centerIn: parent
            spacing: 8
            Orb { sid: pill.modelData; running: true; idleBlur: 0; width: 16; height: 16; anchors.verticalCenter: parent.verticalCenter }
            Text {
              text: pill.modelData + "  " + root.activityLabelFor(pill.modelData)
              textFormat: Text.PlainText
              color: root.contentColor
              font.family: root.bodyFont; font.pixelSize: root.fsMeta; font.weight: 500
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }
      }
    }

    delegate: Item {
      id: row
      required property string key
      required property int index
      readonly property var entry: root.rows[index] || ({ kind: "day", diff: [] })
      readonly property string kind: entry.kind
      readonly property bool current: index === root.cursor && root.focused
      readonly property real dotY: kind === "file" ? fileHead.y + fileHead.height / 2 : height / 2
      width: list.width
      height: kind === "day" ? 52 : kind === "head" ? headCol.implicitHeight + 30 : kind === "result" ? resultText.implicitHeight + 18
        : fileBox.height + 6

      CapLabel {
        visible: row.kind === "day"
        anchors { bottom: parent.bottom; bottomMargin: 8; left: parent.left; leftMargin: 8 }
        text: String(row.entry.text || "").toUpperCase()
      }

      Item {
        visible: row.kind === "head"
        anchors.fill: parent
        Orb { id: headOrb; sid: row.entry.sid || ""; running: root.busy(row.entry.sid); x: 8; y: 24; width: 20; height: 20 }
        Column {
          id: headCol
          anchors { left: headOrb.right; leftMargin: 12; right: headTime.left; rightMargin: 16 }
          y: headOrb.y + headOrb.height / 2 - headName.implicitHeight / 2
          spacing: 4
          Row {
            width: parent.width
            spacing: 12
            Text {
              id: headName
              text: row.entry.sid || ""; textFormat: Text.PlainText
              color: root.contentColor
              font.family: root.bodyFont; font.pixelSize: root.fsName; font.weight: 600
            }
            Text {
              width: parent.width - headName.width - 12
              anchors.baseline: headName.baseline
              text: (row.entry.done ? "\u2713 " : "") + (row.entry.task || row.entry.prompt || "")
              textFormat: Text.PlainText
              wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight
              lineHeightMode: Text.FixedHeight; lineHeight: root.fsBody * 1.4
              color: row.entry.done ? Theme.green : root.contentColor
              font.family: root.bodyFont; font.pixelSize: root.fsBody
            }
          }
          Text {
            visible: !!row.entry.task && !!row.entry.prompt
            width: parent.width
            text: (row.entry.from && row.entry.from !== "you" ? row.entry.from : "You") + ": " + (row.entry.prompt || "")
            textFormat: Text.PlainText
            wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
            color: root.metaColor
            font.family: root.bodyFont; font.pixelSize: root.fsMeta
          }
        }
        Text {
          id: headTime
          anchors { right: parent.right; rightMargin: 12; verticalCenter: headOrb.verticalCenter }
          text: root.busy(row.entry.sid) ? root.activityLabelFor(row.entry.sid || "") : root.clock(row.entry.end || 0)
          color: root.busy(row.entry.sid) ? Theme.orange : root.metaColor
          font.family: root.bodyFont; font.pixelSize: root.fsMeta - 1
        }
      }

      Rectangle {
        id: fileBox
        visible: row.kind === "file"
        x: 18
        width: parent.width - 18
        height: visible ? fileCol.implicitHeight + 16 : 0
        radius: 12
        color: row.current ? Qt.alpha(Theme.fg, 0.05) : fileHover.hovered ? Qt.alpha(Theme.fg, 0.03) : "transparent"
        border.width: row.current ? 1 : 0
        border.color: root.rail ? root.rail.cardRing : Qt.alpha(Theme.fg, 0.18)
        HoverHandler { id: fileHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: { root.cursorKey = row.key; root.forceActiveFocus(); root.open() } }

        Column {
          id: fileCol
          x: 22; y: 8
          width: parent.width - 34
          spacing: 6
          Item {
            id: fileHead
            width: parent.width
            height: Math.max(pathText.implicitHeight, 20)
            Icon { id: fileIcon; name: "file-content"; width: 14; height: 14; color: root.metaColor; anchors.verticalCenter: parent.verticalCenter }
            Text {
              id: pathText
              anchors { left: fileIcon.right; leftMargin: 10; right: fileMeta.left; rightMargin: 12; verticalCenter: parent.verticalCenter }
              readonly property string rel: root.relPath(row.entry.sid, row.entry.path)
              readonly property int cut: rel.lastIndexOf("/") + 1
              textFormat: Text.StyledText
              text: '<font color="' + root.metaColor + '">' + rel.slice(0, cut).replace(/&/g, "&amp;").replace(/</g, "&lt;") + '</font>'
                + rel.slice(cut).replace(/&/g, "&amp;").replace(/</g, "&lt;")
                + (row.entry.line > 1 ? '<font color="' + root.metaColor + '">:' + row.entry.line + '</font>' : "")
              elide: Text.ElideLeft
              color: root.contentColor
              font.family: Theme.fontFamily; font.pixelSize: root.fsMeta
            }
            Row {
              id: fileMeta
              anchors { right: parent.right; verticalCenter: parent.verticalCenter }
              spacing: 10
              Text { text: "+" + (row.entry.add || 0); color: Theme.green; font.family: Theme.fontFamily; font.pixelSize: root.fsMeta - 1 }
              Text { text: "-" + (row.entry.del || 0); color: Theme.red; font.family: Theme.fontFamily; font.pixelSize: root.fsMeta - 1 }
              Text {
                text: (row.entry.edits > 1 ? row.entry.edits + " edits  " : "") + root.clock(row.entry.at || 0)
                color: root.metaColor; font.family: root.bodyFont; font.pixelSize: root.fsMeta - 1
              }
            }
          }
          Text {
            visible: !!row.entry.why
            width: parent.width
            leftPadding: 24
            text: row.entry.why || ""
            textFormat: Text.PlainText
            color: Theme.fg_secondary
            font.family: root.bodyFont; font.pixelSize: root.fsMeta
            lineHeightMode: Text.FixedHeight; lineHeight: root.fsMeta * 1.45
            wrapMode: Text.Wrap; maximumLineCount: row.current ? 6 : 2; elide: Text.ElideRight
          }
          Column {
            width: parent.width
            visible: (row.entry.diff || []).length > 0
            Repeater {
              model: (row.entry.diff || []).slice(0, row.current ? 12 : 3)
              delegate: Rectangle {
                required property string modelData
                readonly property var parts: modelData.match(/^([+-])\s*(\d+) ?(.*)$/) || ["", " ", "", modelData]
                width: parent.width
                height: 20
                color: Qt.alpha(parts[1] === "+" ? Theme.green : Theme.red, 0.07)
                Text {
                  id: lineNo
                  width: 44; x: 4
                  anchors.verticalCenter: parent.verticalCenter
                  horizontalAlignment: Text.AlignRight
                  text: parts[2]
                  color: root.metaColor
                  font.family: Theme.fontFamily; font.pixelSize: root.fsMeta - 2
                }
                Text {
                  anchors { left: lineNo.right; leftMargin: 10; right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
                  text: parts[1] + " " + parts[3]
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: parts[1] === "+" ? Theme.green : Theme.red
                  font.family: Theme.fontFamily; font.pixelSize: root.fsMeta - 2
                }
              }
            }
          }
        }
      }

      Text {
        id: resultText
        visible: row.kind === "result"
        x: 40; y: 4
        width: parent.width - 52
        text: "\u27e2 " + (row.entry.text || "")
        textFormat: Text.PlainText
        color: Theme.fg_secondary
        font.family: root.bodyFont; font.pixelSize: root.fsMeta
        lineHeightMode: Text.FixedHeight; lineHeight: root.fsMeta * 1.45
        wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
      }
    }

    Text {
      visible: !root.rows.length && !root.working.length
      anchors.centerIn: parent
      text: "No code changes yet"
      color: root.metaColor
      font.family: root.bodyFont; font.pixelSize: root.fsBody
    }
  }

  Rectangle {
    width: 8; height: 8; radius: 4
    color: Theme.cursor
    visible: !!root.restPoint && !root.caretHeld && root.restPoint.y > 0 && root.restPoint.y < root.height
    x: root.restPoint ? root.restPoint.x - width / 2 : 0
    y: root.restPoint ? root.restPoint.y - height / 2 : 0
    Behavior on x { enabled: parent.visible; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    Behavior on y { enabled: parent.visible; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
  }
}

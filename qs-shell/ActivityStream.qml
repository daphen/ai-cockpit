import QtQuick
import QsLib

FocusScope {
  id: root
  property color color: Theme.bg
  property var agentd: null
  property var rail: null
  property var sessions: []
  property color muted: Theme.fg_muted
  property var activityLabelFor: sid => "idle"
  property string cursorKey: ""
  readonly property bool focused: activeFocus
  signal sessionRequested(string sid)
  signal focusRequested(string direction)
  onVisibleChanged: if (visible) { if (agentd) agentd.loadActivityHistory(); Qt.callLater(scroller.toEnd) }
  FeedScroll { id: scroller; view: list; chatVisible: root.visible }

  Keys.onPressed: event => {
    var ctrl = event.modifiers & Qt.ControlModifier
    if (ctrl && event.key === Qt.Key_L) focusRequested("right")
    else if (ctrl && event.key === Qt.Key_H) focusRequested("left")
    else if (event.key === Qt.Key_J || event.key === Qt.Key_Down) move(1)
    else if (event.key === Qt.Key_K || event.key === Qt.Key_Up) move(-1)
    else if (event.key === Qt.Key_G) edge(event.modifiers & Qt.ShiftModifier)
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
  readonly property color lavender: rail ? rail.lavenderAccent : "#C4B5FD"
  readonly property color ring: rail ? rail.cardRing : Qt.alpha(Theme.fg, 0.18)
  readonly property color contentColor: light ? "#23272B" : "#FAFAFA"
  readonly property color bodyColor: light ? "#343A3F" : "#EDEDED"
  readonly property color metaColor: light ? "#747D84" : "#909090"

  function base(path) { var s = String(path || ""); return s.slice(s.lastIndexOf("/") + 1) }
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

  readonly property var working: sessions.filter(s => busy(s.name)).map(s => s.name)
  // A turn opens at a prompt once the previous turn has a result, and closes at its summary.
  readonly property var turns: {
    if (!agentd) return []
    agentd.activityGen
    var src = agentd.activity.slice().sort((a, b) => a.at - b.at)
    var list = [], open = {}
    for (var r of src) {
      var t = open[r.sid]
      if (!t || (r.kind === "prompt" && t.summary) || (r.kind === "summary" && t.summary)) {
        t = { key: "turn:" + r.key, sid: r.sid, end: r.at, prompts: [], task: "", taskDone: false,
              summary: "", files: [], add: 0, del: 0, asks: [] }
        open[r.sid] = t
        list.push(t)
      }
      t.end = Math.max(t.end, r.at)
      if (r.kind === "prompt") t.prompts.push(r)
      else if (r.kind === "summary") t.summary = r.text
      else if (r.kind === "task") { t.task = r.text; t.taskDone = r.action === "finish" }
      else if (r.kind === "ask") t.asks.push(r.text)
      else if (r.kind === "edit") {
        if (t.files.indexOf(base(r.path)) < 0) t.files.push(base(r.path))
        t.add += r.add || 0; t.del += r.del || 0
      }
    }
    for (var sid in open) open[sid].latest = true
    return list.sort((a, b) => a.end - b.end)
  }
  readonly property var rows: {
    var out = [], day = "", prev = ""
    for (var t of turns) {
      var label = dayLabel(t.end)
      if (label !== day) { out.push({ kind: "day", key: "day:" + label, text: label, prompts: [], files: [], asks: [] }); day = label; prev = "" }
      out.push(Object.assign({ kind: "turn", showSession: t.sid !== prev }, t))
      prev = t.sid
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
    for (i = rows.length - 1; i >= 0 && rows[i].kind === "day"; i--);
    return i
  }
  readonly property string currentSession: cursor >= 0 ? rows[cursor].sid : ""

  function select(i) {
    cursorKey = rows[i].key
    scroller.cursorMoved(i, i === rows.length - 1)
  }
  function move(delta) {
    for (var i = cursor + delta; i >= 0 && i < rows.length; i += delta)
      if (rows[i].kind !== "day") { select(i); return }
  }
  function edge(last) {
    for (var n = 0; n < rows.length; n++) {
      var i = last ? rows.length - 1 - n : n
      if (rows[i].kind !== "day") { select(i); return }
    }
  }
  function open() { if (currentSession) sessionRequested(currentSession) }

  component Orb: ThinkingOrb {
    required property string sid
    readonly property var colors: root.rail ? root.rail.fleetActivityColors(sid) : []
    running: false
    activityColors: colors
    glow: colors.length ? colors[0] : "#999999"
    seedKey: sid
    idleBlur: 1
  }
  component MetaLine: Row {
    property string icon
    property color iconColor: root.metaColor
    property alias text: label.text
    property color color: Theme.fg_secondary
    spacing: 8
    Icon { name: parent.icon; width: 14; height: 14; color: parent.iconColor; anchors.verticalCenter: parent.verticalCenter }
    Text {
      id: label
      width: Math.min(implicitWidth, parent.width - 22)
      elide: Text.ElideRight; textFormat: Text.PlainText
      color: parent.color
      font.family: root.bodyFont; font.pixelSize: root.fsMeta
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  ListView {
    id: list
    width: Math.min(parent.width - 64, 1400)
    height: parent.height
    anchors.horizontalCenter: parent.horizontalCenter
    header: Item { height: 20 }
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    model: ListModel { id: rowModel }
    cacheBuffer: 1000000
    ScrollFeel { flick: list; onScrolled: up => scroller.userScrolled(up) }
    onDraggingChanged: dragging ? scroller.gestureStarted() : scroller.gestureEnded()

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
      readonly property var turn: root.rows[index] || ({ kind: "day", prompts: [], files: [], asks: [] })
      readonly property bool day: turn.kind === "day"
      readonly property bool current: index === root.cursor && root.focused
      readonly property bool live: !day && turn.latest === true && !turn.summary && root.busy(turn.sid)
      readonly property var prompt: day ? null : turn.prompts[0] || null
      readonly property bool handoff: !!prompt && prompt.from !== "you"
      width: list.width
      height: day ? 56 : frame.height + (turn.showSession ? 64 : 8)

      CapLabel {
        visible: row.day
        anchors { bottom: parent.bottom; bottomMargin: 10; left: parent.left; leftMargin: 18 }
        text: String(row.turn.text || "").toUpperCase()
      }

      Item {
        id: head
        visible: row.turn.showSession === true
        width: parent.width; height: 60
        readonly property var session: root.sessions.find(x => x.name === row.turn.sid) || ({})
        readonly property string where: String(session.cwd || "").replace(/^\/home\/[^/]+/, "~")
        Rectangle {
          visible: index > 0 && root.rows[index - 1].kind !== "day"
          x: 18; width: parent.width - 36; height: 1; y: 6
          color: Qt.alpha(Theme.fg, 0.07)
        }
        Orb { id: headOrb; sid: row.turn.sid || ""; running: root.busy(row.turn.sid); x: 18; y: 22; width: 26; height: 26 }
        Column {
          anchors { left: headOrb.right; leftMargin: 12; right: headState.left; rightMargin: 12; verticalCenter: headOrb.verticalCenter }
          spacing: 1
          Text {
            width: parent.width; elide: Text.ElideRight
            text: row.turn.sid || ""; textFormat: Text.PlainText
            color: root.contentColor
            font.family: root.bodyFont; font.pixelSize: root.fsName + 1; font.weight: 600
          }
          Text {
            width: parent.width; elide: Text.ElideMiddle
            text: [head.where, head.session.plan].filter(x => !!x).join("  \u00b7  ")
            textFormat: Text.PlainText
            color: root.metaColor
            font.family: root.bodyFont; font.pixelSize: root.fsMeta - 1
          }
        }
        Text {
          id: headState
          anchors { right: parent.right; rightMargin: 20; verticalCenter: headOrb.verticalCenter }
          text: root.busy(row.turn.sid) ? root.activityLabelFor(row.turn.sid || "") : head.session.name ? "idle" : "closed"
          color: root.busy(row.turn.sid) ? Theme.orange : root.metaColor
          font.family: root.bodyFont; font.pixelSize: root.fsMeta - 1; font.weight: 500
        }
      }

      Rectangle {
        id: frame
        visible: !row.day
        y: row.turn.showSession ? 64 : 4
        width: parent.width
        height: col.implicitHeight + 24
        radius: 18
        color: hover.hovered && !row.current ? Qt.alpha(Theme.fg, 0.03) : "transparent"
        border.width: row.current ? 1 : 0
        border.color: root.ring

        Rectangle {
          x: 10 - width / 2; y: 12 + Math.round(root.fsBody * 0.7) - height / 2
          width: 8; height: 8; radius: 4
          color: Theme.cursor
          visible: row.current
        }

        Column {
          id: col
          x: 24; y: 12
          width: parent.width - 48
          spacing: 10

          Text {
            visible: !row.prompt
            text: root.clock(row.turn.end || 0)
            color: root.metaColor
            font.family: root.bodyFont; font.pixelSize: root.fsMeta - 1
          }

          Rectangle {
            visible: !!row.prompt
            width: col.width
            height: promptCol.implicitHeight + 24
            radius: 14
            color: row.handoff ? Qt.rgba(root.lavender.r, root.lavender.g, root.lavender.b, 0.08) : "transparent"
            border.width: row.handoff ? 1 : 0
            border.color: Qt.rgba(root.lavender.r, root.lavender.g, root.lavender.b, 0.22)
            ContrastCard {
              visible: !row.handoff
              anchors.fill: parent
              cardRadius: parent.radius
              bevelWidth: root.light ? 1 : 2
              faceTop: root.light ? "#FDFDFD" : (root.rail ? root.rail.userCardTop : Theme.surface0)
              faceUpper: faceTop
              faceMid: root.light ? "#F8F8F9" : (root.rail ? root.rail.userCardBottom : Theme.surface0)
              faceBottom: faceMid
              rimBottom: root.light ? "#F3F3F4" : "#222222"
              outlineColor: root.light ? Qt.alpha(Theme.fg, 0.11) : "#282828"
            }
            Column {
              id: promptCol
              x: 16; y: 12
              width: parent.width - 32
              spacing: 6
              Item {
              width: parent.width
              height: promptHead.implicitHeight
              Row {
                id: promptHead
                spacing: 8
                Icon {
                  name: row.handoff ? "sparkle-3" : "paper-plane-2"
                  variantSize: row.handoff ? 0 : 12
                  width: 14; height: 14; anchors.verticalCenter: parent.verticalCenter
                  color: row.handoff ? root.lavender : Theme.orange
                }
                Text {
                  text: !row.prompt ? "" : row.handoff ? "From " + row.prompt.from : "You"
                  color: root.contentColor
                  font.family: root.bodyFont; font.pixelSize: root.fsMeta; font.weight: 600
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  visible: row.turn.prompts.length > 1
                  text: "+" + (row.turn.prompts.length - 1) + " more"
                  color: root.metaColor
                  font.family: root.bodyFont; font.pixelSize: root.fsMeta - 1
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
              Text {
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                text: root.clock(row.turn.end || 0)
                color: root.metaColor
                font.family: root.bodyFont; font.pixelSize: root.fsMeta - 1
              }
              }
              Text {
                width: parent.width
                text: row.prompt ? row.prompt.text : ""
                textFormat: Text.PlainText
                color: root.bodyColor
                font.family: root.bodyFont; font.pixelSize: root.fsBody
                lineHeightMode: Text.FixedHeight; lineHeight: root.fsBody * 1.5
                wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
              }
            }
          }

          MetaLine {
            visible: !!row.turn.task
            width: col.width
            icon: row.turn.taskDone ? "check" : "bookmark"
            iconColor: row.turn.taskDone ? Theme.green : root.metaColor
            text: row.turn.task || ""
          }
          Row {
            visible: !!row.turn.summary || row.live
            width: col.width
            spacing: 8
            Text {
              text: row.turn.summary ? "\u27e2" : "\u2026"
              color: root.metaColor
              font.family: root.bodyFont; font.pixelSize: root.fsBody
              lineHeightMode: Text.FixedHeight; lineHeight: root.fsBody * 1.5
            }
            Text {
              width: parent.width - 24
              text: row.turn.summary || "Working \u00b7 " + root.activityLabelFor(row.turn.sid || "")
              textFormat: Text.PlainText
              color: row.turn.summary ? root.contentColor : root.metaColor
              font.family: root.bodyFont; font.pixelSize: root.fsBody
              lineHeightMode: Text.FixedHeight; lineHeight: root.fsBody * 1.5
              wrapMode: Text.Wrap; maximumLineCount: 4; elide: Text.ElideRight
            }
          }
          MetaLine {
            visible: row.turn.asks.length > 0
            width: col.width
            icon: "msg-bubble-user"
            iconColor: Theme.orange
            text: row.turn.asks.length ? row.turn.asks[row.turn.asks.length - 1] : ""
          }
          Row {
            visible: row.turn.files.length > 0
            width: col.width
            spacing: 8
            Icon { name: "square-plus"; width: 14; height: 14; color: root.metaColor; anchors.verticalCenter: parent.verticalCenter }
            Text {
              width: Math.min(implicitWidth, col.width - 120)
              elide: Text.ElideRight; textFormat: Text.PlainText
              text: row.turn.files.join(", ")
              color: Theme.fg_secondary
              font.family: root.bodyFont; font.pixelSize: root.fsMeta
              anchors.verticalCenter: parent.verticalCenter
            }
            Text { text: "+" + row.turn.add; color: Theme.green; font.family: root.bodyFont; font.pixelSize: root.fsMeta; anchors.verticalCenter: parent.verticalCenter }
            Text { text: "-" + row.turn.del; color: Theme.red; font.family: root.bodyFont; font.pixelSize: root.fsMeta; anchors.verticalCenter: parent.verticalCenter }
          }
        }
      }
      HoverHandler { id: hover; enabled: !row.day; cursorShape: Qt.PointingHandCursor }
      TapHandler { enabled: !row.day; onTapped: { root.cursorKey = row.turn.key; root.open() } }
    }

    Text {
      visible: !root.rows.length && !root.working.length
      anchors.centerIn: parent
      text: "No activity yet"
      color: root.metaColor
      font.family: root.bodyFont; font.pixelSize: root.fsBody
    }
  }
}

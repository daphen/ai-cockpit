import QtQuick
import Quickshell.Io
import QsLib

FocusScope {
  id: root
  property color color: Theme.bg
  property var agentd: null
  property var rail: null
  property var sessions: []
  property string cursorKey: ""
  property bool caretHeld: false
  readonly property bool focused: activeFocus
  signal sessionRequested(string sid)
  signal fileRequested(string sid, string path, int line)
  signal focusRequested(string direction)

  function cursorPoint() {
    var item = cursor >= 0 ? list.itemAtIndex(cursor) : null
    return item ? item.mapToItem(root, 4, item.dotY) : null
  }
  readonly property var restPoint: { list.contentY; list.contentHeight; cursor; width; return activeFocus ? cursorPoint() : null }
  function reveal() { if (agentd) agentd.loadActivityHistory(); Qt.callLater(scroller.toEnd) }
  onVisibleChanged: if (visible) { reveal(); refreshGit() }
  onSessionsChanged: if (visible && agentd) { agentd.loadActivityHistory(); gitAgain.restart() }
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
  function esc(text) { return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }
  function relPath(sid, path) {
    var cwd = String((sessions.find(s => s.name === sid) || {}).cwd || "")
    var p = String(path || "")
    if (cwd && p.indexOf(cwd + "/") === 0) return p.slice(cwd.length + 1)
    return p.replace(/^\/home\/[^/]+/, "~")
  }


  // Commits fill in what the edit tool never saw (changes made through shell commands).
  property var repos: ({})
  property var _gitQueue: []
  function refreshGit() {
    if (gitRun.running) { gitAgain.restart(); return }
    var seen = {}
    _gitQueue = sessions.map(s => String(s.cwd || "")).filter(c => c && !seen[c] && (seen[c] = true))
    gitNext()
  }
  function gitNext() {
    if (!_gitQueue.length) return
    gitRun.cwd = _gitQueue.shift()
    gitRun.command = ["sh", "-c", 'top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || exit 0; printf "%s\\n" "$top"; '
      + 'git -C "$top" log --since=@"$2" --no-merges -p -U1 --no-color --no-ext-diff --format="%x1e%H%x1f%ct%x1f%s" | head -c 4000000',
      "sh", gitRun.cwd, String(Math.floor(Date.now() / 1000) - 3 * 86400)]
    gitRun.running = true
  }
  function parseLog(text) {
    var chunks = String(text).split("\x1e"), top = chunks[0].trim(), commits = []
    for (var c = 1; c < chunks.length; c++) {
      var body = chunks[c].split("\n"), head = body[0].split("\x1f"), files = [], f = null, oldLn = 0, newLn = 0, hunk = false
      for (var i = 1; i < body.length; i++) {
        var l = body[i], m
        if ((m = l.match(/^diff --git a\/.* b\/(.*)$/))) { f = { path: top + "/" + m[1], add: 0, del: 0, line: 0, diff: [] }; files.push(f); hunk = false }
        else if (!f) continue
        else if ((m = l.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/))) { oldLn = +m[1]; newLn = +m[2]; hunk = true; if (f.diff.length) f.diff.push("\u22ef") }
        else if (!hunk) continue
        else if (l[0] === "+") { f.add++; if (!f.line) f.line = newLn; if (f.diff.length < 60) f.diff.push("+" + newLn + " " + l.slice(1, 200)); newLn++ }
        else if (l[0] === "-") { f.del++; if (!f.line) f.line = newLn; if (f.diff.length < 60) f.diff.push("-" + oldLn + " " + l.slice(1, 200)); oldLn++ }
        else if (l[0] === " ") { if (f.diff.length < 60) f.diff.push(" " + newLn + " " + l.slice(1, 200)); oldLn++; newLn++ }
      }
      commits.push({ hash: head[0], at: Number(head[1]) * 1000, subject: head[2] || "", files: files.slice(0, 40) })
    }
    return { top: top, commits: commits }
  }
  Process {
    id: gitRun
    property string cwd
    stdout: StdioCollector {
      onStreamFinished: {
        var out = String(this.text || "")
        if (out.trim()) { var r = root.parseLog(out), next = Object.assign({}, root.repos); next[gitRun.cwd] = r; root.repos = next }
        root.gitNext()
      }
    }
  }
  Timer { id: gitAgain; interval: 3000; onTriggered: root.refreshGit() }
  Connections { target: root.agentd; function onActivityGenChanged() { if (root.visible) gitAgain.restart() } }

  // One flat timeline of changes; the session's ask is repeated only when it changes.
  readonly property var changes: {
    if (!agentd) return []
    agentd.activityGen
    var src = agentd.activity.slice().sort((a, b) => a.at - b.at)
    var ctx = {}, events = [], editsBy = {}, lastSeen = {}
    for (var r of src) {
      if (r.kind === "prompt" || r.kind === "edit") (lastSeen[r.sid] = lastSeen[r.sid] || []).push(r.at)
      if (r.kind === "task" && r.action === "switch") ctx[r.sid] = { text: r.text, from: "task" }
      else if (r.kind === "prompt") ctx[r.sid] = { text: r.text, from: r.from || "you" }
      if (r.kind !== "edit") continue
      ;(editsBy[r.sid] = editsBy[r.sid] || []).push(r)
      events.push({ sid: r.sid, at: r.at, ctx: ctx[r.sid] || { text: "", from: "" }, why: r.why || "", whole: !!r.whole,
                    files: [{ path: r.path, add: r.add || 0, del: r.del || 0, line: r.line || 1 }],
                    diff: r.whole ? [] : (r.diff || []), lines: r.lines || 0, key: r.key })
    }
    var tops = {}
    for (var cwd in repos) {
      var repo = repos[cwd]
      if (tops[repo.top]) continue
      tops[repo.top] = true
      var owners = sessions.filter(s => repos[s.cwd] && repos[s.cwd].top === repo.top).map(s => s.name)
      var commits = repo.commits.slice().sort((a, b) => a.at - b.at)
      for (var ci = 0; ci < commits.length; ci++) {
        var cm = commits[ci], since = ci ? commits[ci - 1].at : 0
        var owner = owners[0], best = -1
        for (var o of owners) for (var t of (lastSeen[o] || [])) if (t <= cm.at + 60000 && t > best) { best = t; owner = o }
        if (!owner) continue
        var covered = (editsBy[owner] || []).filter(e => e.at > since && e.at <= cm.at + 60000).map(e => e.path)
        var fresh = cm.files.filter(f => covered.indexOf(f.path) < 0)
        var diff = []
        for (var f of fresh) diff = diff.concat(cm.files.length > 1 ? ["\u0001" + f.path] : []).concat(f.diff)
        var c = ctx[owner]
        for (var q of src) if (q.sid === owner && q.at <= cm.at && (q.kind === "prompt" || (q.kind === "task" && q.action === "switch"))) c = { text: q.text, from: q.kind === "task" ? "task" : q.from || "you" }
        events.push({ sid: owner, at: cm.at, ctx: c || { text: "", from: "" }, why: cm.subject, commit: true, whole: false,
                      files: cm.files.map(f => ({ path: f.path, add: f.add, del: f.del, line: f.line || 1, covered: covered.indexOf(f.path) >= 0 })),
                      diff: diff, lines: fresh.reduce((n, f) => n + f.add + f.del, 0), key: "commit:" + cm.hash })
      }
    }
    events.sort((a, b) => a.at - b.at)
    var out = []
    for (var e of events) {
      var prev = out[out.length - 1]
      var sameAsk = prev && prev.sid === e.sid && prev.ctx.text === e.ctx.text && !prev.commit && !e.commit && e.at - prev.at < 300000
      if (sameAsk && prev.whole && e.whole) { prev.files = prev.files.concat(e.files); prev.at = e.at; continue }
      if (sameAsk && !prev.whole && !e.whole && prev.files.length === 1 && prev.files[0].path === e.files[0].path) {
        var pf = prev.files[0]
        pf.add += e.files[0].add; pf.del += e.files[0].del
        prev.diff = prev.diff.concat(prev.diff.length && e.diff.length ? ["\u22ef"] : []).concat(e.diff).slice(0, 80)
        prev.lines += e.lines; prev.edits = (prev.edits || 1) + 1; prev.at = e.at
        if (!prev.why) prev.why = e.why
        continue
      }
      out.push(e)
    }
    return out.slice(-200)
  }
  readonly property var rows: {
    var out = [], day = "", prev = null
    for (var e of changes) {
      var label = dayLabel(e.at)
      if (label !== day) { out.push({ kind: "day", key: "day:" + label, text: label }); day = label; prev = null }
      if (!prev || prev.sid !== e.sid || prev.ctx.text !== e.ctx.text)
        out.push({ kind: "ask", key: "ask:" + e.key, sid: e.sid, text: e.ctx.text, from: e.ctx.from })
      out.push(Object.assign({ kind: "change" }, e))
      prev = e
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
    for (i = rows.length - 1; i >= 0 && rows[i].kind !== "change"; i--);
    return i
  }
  readonly property var currentRow: cursor >= 0 ? rows[cursor] : null

  function select(i) {
    cursorKey = rows[i].key
    var last = rows.length - 1
    while (last > i && rows[last].kind !== "change") last--
    scroller.cursorMoved(i, i === last)
  }
  function move(delta) {
    for (var i = cursor + delta; i >= 0 && i < rows.length; i += delta)
      if (rows[i].kind === "change") { select(i); return }
  }
  function edge(last) {
    for (var n = 0; n < rows.length; n++) {
      var i = last ? rows.length - 1 - n : n
      if (rows[i].kind === "change") { select(i); return }
    }
  }
  function open() {
    if (!currentRow || currentRow.kind !== "change") return
    var f = currentRow.files.find(x => !x.covered) || currentRow.files[0]
    fileRequested(currentRow.sid, f.path, f.line || 1)
  }

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

    footer: Item { height: 24 }

    delegate: Item {
      id: row
      required property string key
      required property int index
      readonly property var entry: root.rows[index] || ({ kind: "day", files: [], diff: [] })
      readonly property string kind: entry.kind
      readonly property bool current: index === root.cursor && root.focused
      readonly property real dotY: kind === "change" ? changeBox.y + changeCol.y + pills.y + 13 : height / 2
      width: list.width
      height: kind === "day" ? 52 : kind === "ask" ? askCol.implicitHeight + 22 : changeBox.height + 6

      CapLabel {
        visible: row.kind === "day"
        anchors { bottom: parent.bottom; bottomMargin: 8; left: parent.left; leftMargin: 8 }
        text: String(row.entry.text || "").toUpperCase()
      }

      Row {
        id: askCol
        visible: row.kind === "ask"
        x: 8; y: 16
        width: parent.width - 16
        spacing: 10
        Orb { id: askOrb; sid: row.entry.sid || ""; running: false; width: 18; height: 18; y: (askName.implicitHeight - height) / 2 }
        Text {
          id: askName
          text: row.entry.sid || ""; textFormat: Text.PlainText
          color: root.contentColor
          font.family: root.bodyFont; font.pixelSize: root.fsName; font.weight: 600
        }
        Text {
          width: parent.width - askOrb.width - askName.width - 20
          anchors.baseline: askName.baseline
          text: !row.entry.text ? "" : row.entry.from === "task" ? row.entry.text
            : (row.entry.from && row.entry.from !== "you" ? row.entry.from + ": " : "") + "\u201c" + row.entry.text + "\u201d"
          textFormat: Text.PlainText
          wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
          lineHeightMode: Text.FixedHeight; lineHeight: root.fsBody * 1.4
          color: row.entry.from === "task" ? root.contentColor : Theme.fg_secondary
          font.family: root.bodyFont; font.pixelSize: root.fsBody
        }
      }

      Rectangle {
        id: changeBox
        visible: row.kind === "change"
        x: 0
        width: parent.width
        height: visible ? changeCol.implicitHeight + 14 : 0
        radius: 12
        color: row.current ? Qt.alpha(Theme.fg, 0.05) : changeHover.hovered ? Qt.alpha(Theme.fg, 0.03) : "transparent"
        border.width: row.current ? 1 : 0
        border.color: root.rail ? root.rail.cardRing : Qt.alpha(Theme.fg, 0.18)
        HoverHandler { id: changeHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: { root.cursorKey = row.key; root.forceActiveFocus(); root.open() } }

        Text {
          id: timeText
          x: 10; y: changeCol.y + pills.y + (26 - height) / 2
          width: 44
          text: root.clock(row.entry.at || 0)
          color: root.metaColor
          font.family: root.bodyFont; font.pixelSize: root.fsMeta - 1
        }
        Column {
          id: changeCol
          x: 64; y: 7
          width: parent.width - 76
          spacing: 6
          Item {
            width: parent.width
            height: pills.height
            Flow {
              id: pills
              width: parent.width - counts.width - 16
              spacing: 6
              Repeater {
                model: row.kind === "change" ? row.entry.files : []
                delegate: PillSurface {
                  id: filePill
                  required property var modelData
                  readonly property string rel: root.relPath(row.entry.sid, modelData.path)
                  readonly property int cut: rel.lastIndexOf("/") + 1
                  height: 26; radius: 13
                  width: Math.min(pathText.implicitWidth + 40, pills.width)
                  opacity: modelData.covered ? 0.55 : 1
                  Icon { id: fileIcon; x: 9; name: "file-content"; width: 12; height: 12; color: "#9A6500"; anchors.verticalCenter: parent.verticalCenter }
                  Text {
                    id: pathText
                    anchors { left: fileIcon.right; leftMargin: 6; right: parent.right; rightMargin: 9; verticalCenter: parent.verticalCenter }
                    textFormat: Text.StyledText
                    text: '<font color="' + root.metaColor + '">' + root.esc(filePill.rel.slice(0, filePill.cut)) + '</font>' + root.esc(filePill.rel.slice(filePill.cut))
                    elide: Text.ElideLeft
                    color: filePill.contentColor
                    font.family: Theme.fontFamily; font.pixelSize: root.fsMeta; font.weight: 500
                  }
                }
              }
            }
            Row {
              id: counts
              anchors { right: parent.right; top: parent.top; topMargin: (26 - height) / 2 }
              spacing: 10
              readonly property int add: (row.entry.files || []).reduce((n, f) => n + f.add, 0)
              readonly property int del: (row.entry.files || []).reduce((n, f) => n + f.del, 0)
              Text { text: "+" + counts.add; color: Theme.green; font.family: Theme.fontFamily; font.pixelSize: root.fsMeta }
              Text { text: "-" + counts.del; color: Theme.red; font.family: Theme.fontFamily; font.pixelSize: root.fsMeta }
            }
          }
          Text {
            visible: !!row.entry.why
            width: parent.width
            text: (row.entry.commit ? "Committed: " : "") + (row.entry.why || "")
            textFormat: Text.PlainText
            color: Theme.fg_secondary
            font.family: root.bodyFont; font.pixelSize: root.fsMeta
            lineHeightMode: Text.FixedHeight; lineHeight: root.fsMeta * 1.45
            wrapMode: Text.Wrap; maximumLineCount: row.current ? 6 : 2; elide: Text.ElideRight
          }
          Text {
            visible: row.entry.whole === true
            text: ((row.entry.files || []).length > 1 ? "Wrote " + row.entry.files.length + " new files" : "Wrote the whole file") + " \u00b7 Enter opens it"
            color: root.metaColor
            font.family: root.bodyFont; font.pixelSize: root.fsMeta - 1
          }
          Rectangle {
            id: diffPanel
            visible: (row.entry.diff || []).length > 0
            width: parent.width
            height: visible ? diffCol.implicitHeight + 12 : 0
            radius: 12
            color: root.rail ? root.rail.codePanelColor : Qt.alpha(Theme.fg, 0.05)
            clip: true
            Column {
              id: diffCol
              anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 6 }
              Repeater {
                model: (row.entry.diff || []).slice(0, row.current ? 40 : 14)
                delegate: Rectangle {
                  required property string modelData
                  required property int index
                  readonly property bool fileHeader: modelData.charAt(0) === "\u0001"
                  readonly property var parts: modelData.match(/^([+\- ])\s*(\d*)\s?(.*)$/) || ["", " ", "", modelData]
                  readonly property string sign: fileHeader ? "" : parts[1]
                  readonly property string language: {
                    var all = row.entry.diff || []
                    for (var k = index; k >= 0; k--) if (all[k].charAt(0) === "\u0001") return root.rail ? root.rail.codeLanguage(all[k].slice(1)) : ""
                    return root.rail && row.entry.files.length ? root.rail.codeLanguage(row.entry.files[0].path) : ""
                  }
                  width: diffCol.width
                  height: diffLine.implicitHeight + (fileHeader && index ? 10 : 3)
                  color: sign === "+" ? Theme.diffAddedBg : sign === "-" ? Theme.diffRemovedBg : "transparent"
                  Rectangle { width: 2; height: parent.height; visible: parent.sign === "+" || parent.sign === "-"; color: parent.sign === "+" ? Theme.green : Theme.red }
                  Text {
                    id: diffLine
                    x: 10; width: parent.width - 16
                    anchors.bottom: parent.bottom; anchors.bottomMargin: 1
                    textFormat: fileHeader ? Text.PlainText : Text.StyledText
                    text: fileHeader ? root.relPath(row.entry.sid, modelData.slice(1))
                      : modelData === "\u22ef" ? "\u22ef"
                      : '<font color="' + Qt.alpha(Theme.fg_muted, 0.75) + '">' + ("    " + parts[2]).slice(-4).replace(/ /g, "&nbsp;") + "&nbsp;&nbsp;</font>"
                        + (root.rail ? root.rail.highlightCode(parts[3], language) : root.esc(parts[3]))
                          .replace(/^[ \t]+/, ws => ws.replace(/\t/g, "    ").replace(/ /g, "&nbsp;"))
                    color: fileHeader || modelData === "\u22ef" ? root.metaColor : Theme.fg
                    font.family: fileHeader ? root.bodyFont : Theme.fontFamily
                    font.pixelSize: root.fsMeta - 2
                    wrapMode: Text.NoWrap; elide: Text.ElideRight; maximumLineCount: 1
                  }
                }
              }
              Text {
                readonly property int hidden: (row.entry.diff || []).length - Math.min((row.entry.diff || []).length, row.current ? 40 : 14)
                visible: hidden > 0
                x: 10; topPadding: 4
                text: "\u2026 " + hidden + " more lines" + (row.current ? " \u00b7 Enter opens the file" : " \u00b7 focus to see more")
                color: root.metaColor; font.family: root.bodyFont; font.pixelSize: root.fsMeta - 1
              }
            }
          }
        }
      }
    }

    Text {
      visible: !root.rows.length
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

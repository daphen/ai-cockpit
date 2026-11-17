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

  function cursorPoint(key) {
    var i = key ? rows.findIndex(r => r.key === key) : cursor
    var item = i >= 0 ? list.itemAtIndex(i) : null
    return item && root.stop(item.kind) ? item.restDot.mapToItem(root, 4, 4) : null
  }
  function reveal() { if (agentd) agentd.loadActivityHistory(); Qt.callLater(scroller.toEnd) }
  onVisibleChanged: if (visible) { reveal(); refreshGit(); jevAgain.restart() }
  onSessionsChanged: if (visible && agentd) { agentd.loadActivityHistory(); gitAgain.restart() }
  FeedScroll { id: scroller; view: list; chatVisible: root.visible }

  // Jev (Typesafe's classifier) scores each ask's card: key = importance 0..1.
  property var jev: ({})
  property var jevAsked: ({})
  property bool importantOnly: false
  // An ask still being worked on is never judged: each new edit would re-score it and flip its preview.
  function working(e) { return !e.outcome && !!agentd && agentd.isBusy(e.sid) }
  function minor(e) { var s = jev[e.jid]; return !working(e) && !!s && s.key < 0.5 }
  function jevNext() {
    if (jevRun.running || !visible) return
    var batch = []
    for (var i = cards.length - 1; i >= 0 && batch.length < 8; i--) {
      var e = cards[i]
      if (!working(e) && !(e.jid in jev) && !jevAsked[e.jid]) batch.push(e)
    }
    if (!batch.length) return
    for (var b of batch) jevAsked[b.jid] = true
    jevRun.command = ["python3", Qt.resolvedUrl("jev-activity.py").toString().replace(/^file:\/\//, ""), JSON.stringify(batch.map(e => {
      var left = 40, last = e.changes[e.changes.length - 1]
      return { id: e.jid, ask: e.ctx.text, outcome: e.outcome || last.why, files: [].concat(...e.changes.map(ch => ch.files.map(f => ({
        path: f.path, lines: f.diff.filter(l => /^[+-]/.test(l) && l.replace(/^[+-]\s*\d*\s?/, "").trim()).slice(0, Math.max(0, left)).map(l => (left--, l.slice(0, 200)))
      })))) }
    }))]
    jevRun.running = true
  }
  Process {
    id: jevRun
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.jev = Object.assign({}, root.jev, JSON.parse(this.text)) } catch (_) {}
        Qt.callLater(root.jevNext)
      }
    }
  }
  Timer { id: jevAgain; interval: 800; onTriggered: root.jevNext() }
  onChangesChanged: jevAgain.restart()

  property string mode: machine.initial
  // The focused file of the focused card; Enter opens it.
  property int file: 0
  // A dimmed card shows no files, so only its top file is reachable, by Enter.
  readonly property var focusFiles: {
    var g = currentRow && currentRow.kind === "card" ? snippet(currentRow) : null
    return !g ? [] : minor(currentRow) ? g.files.slice(0, 1) : g.files
  }
  onCursorKeyChanged: file = 0
  // One state: j/k walk the files of each card, then on to the next card; J/K jump card to card.
  // Each event maps to a next state, or to a handler that does its work and returns one.
  readonly property var machine: ({
    initial: "list",
    states: {
      list: {
        on: {
          focusLeft: () => (focusRequested("left"), "list"),
          focusRight: () => (focusRequested("right"), "list"),
          down: () => (file < focusFiles.length - 1 ? file++ : move(1), "list"),
          up: () => (file > 0 ? file-- : (move(-1), file = Math.max(0, focusFiles.length - 1)), "list"),
          nextCard: () => (move(1), "list"),
          prevCard: () => (move(-1), "list"),
          g: () => (edge(false), "list"),
          bottom: () => (edge(true), "list"),
          enter: () => open(),
          space: () => open(),
          tap: () => open(),
          session: () => (currentRow && sessionRequested(currentRow.sid), "list"),
          filter: () => (importantOnly = !importantOnly, "list")
        }
      }
    }
  })
  function eventOf(e) {
    var k = e.key, shift = e.modifiers & Qt.ShiftModifier
    if (e.modifiers & Qt.ControlModifier)
      return ({ [Qt.Key_H]: "focusLeft", [Qt.Key_L]: "focusRight" })[k] || ""
    return ({ [Qt.Key_J]: shift ? "nextCard" : "down", [Qt.Key_Down]: "down", [Qt.Key_K]: shift ? "prevCard" : "up", [Qt.Key_Up]: "up",
              [Qt.Key_Return]: "enter", [Qt.Key_Enter]: "enter", [Qt.Key_Space]: "space",
              [Qt.Key_G]: shift ? "bottom" : "g", [Qt.Key_S]: "session", [Qt.Key_F]: "filter" })[k] || ""
  }
  Keys.onPressed: event => { if (send({ type: eventOf(event) })) event.accepted = true }
  function send(event) {
    var transition = machine.states[mode].on[event.type]
    if (typeof transition === "function") mode = transition(event)
    else if (transition) mode = transition
    return !!transition
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
  // A few lines that say what changed: declarations added/removed and "old → new" edits;
  // context, blanks, comments, imports and moved lines are dropped.
  // The hunk that best matches what the agent said it did, as real diff lines.
  function snippet(card) {
    var words = t => (String(t).replace(/([a-z])([A-Z])/g, "$1 $2").toLowerCase().match(/[a-z]{3,}/g) || [])
      .filter(w => !/^(the|and|for|with|now|that|this|from|into|var|let|const|function|return|property|readonly|true|false|null|string|bool|int)$/.test(w))
    var want = {}
    for (var w of words((card.outcome || "") + " " + (card.ctx ? card.ctx.text : ""))) want[w] = true
    var trivial = t => !t || /^[\s{}()\[\];,]*$/.test(t) || /^(\/\/|#|\/\*|\*|--)/.test(t) || /^(import|from\s+\S+\s+import|use|#include)\b/.test(t)
    var decl = /^\s*(export\s+|async\s+|default\s+|readonly\s+|required\s+|static\s+|pub\s+)*(function|def|fn|func|class|signal|property|struct|interface|type|enum|const|let|var)\b/
    var isTest = p => /(^|\/)(tests?|__tests__|spec)\/|[._-](test|spec)\.|(^|\/)test_[^/]*$/.test(String(p))
    var files = []
    for (var e of card.changes || [])
      for (var f of e.files || []) {
        if (f.covered) continue
        var file = files.find(x => x.path === f.path)
        if (!file) files.push(file = { path: f.path, name: String(f.path).split("/").pop(), line: f.line || 1, add: 0, del: 0, why: "", best: null, removed: [], test: isTest(f.path) })
        file.add += f.add; file.del += f.del
        if (e.why) file.why = headline(e.why)
        var hunk = []
        var close = () => {
          var real = hunk.filter(l => !trivial(l.text.trim()))
          if (real.length) {
            var hit = {}
            for (var l of real) for (var w of words(l.text)) if (want[w]) hit[w] = true
            var score = 3 * Object.keys(hit).length + Math.min(real.length, 6) + (real.some(l => /\b(function|def|fn|func|class|signal|property|struct|interface|type)\b/.test(l.text)) ? 2 : 0)
            if (!file.best || score > file.best.score) file.best = { score: score, lines: real }
            if (real.every(l => l.sign === "-")) {
              var decls = real.filter(l => decl.test(l.text))
              var lead = Math.min(...decls.map(l => l.text.search(/\S/)))
              for (var d of decls) if (d.text.search(/\S/) === lead) file.removed.push(d)
            }
          }
          hunk = []
        }
        for (var line of f.diff || []) {
          var m = String(line).match(/^([+\-])\s*(\d*)\s?(.*)$/)
          if (m) hunk.push({ sign: m[1], num: m[2], text: m[3].replace(/\t/g, "    ") })
          else close()
        }
        close()
      }
    if (!files.length) return null
    var score = x => x.best ? x.best.score : -1
    files.sort((a, b) => (a.test - b.test) || (score(b) - score(a)))
    for (var x of files) {
      var top = x.best, gone = top && top.lines.every(l => l.sign === "-") && x.removed.length
      if (gone) top = { lines: x.removed.map(l => Object.assign({}, l, { text: l.text.trim().replace(/\s*[{:=]\s*$/, "") })) }
      var lines = top ? top.lines.slice(0, 5) : []
      var indent = lines.length ? Math.min(...lines.map(l => l.text.search(/\S|$/))) : 0
      x.lines = lines.map(l => Object.assign({}, l, { text: l.text.slice(indent) }))
      x.moreLines = top ? top.lines.length - lines.length : 0
      x.removedList = !!gone
    }
    var shown = files.slice(0, 8)
    return { files: shown, more: files.length - 8, path: files[0].path,
             rows: Math.max(...shown.map(x => x.lines.length + (x.moreLines > 0 ? 1 : 0))) }
  }

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
      if (r.kind === "task" && r.action === "switch") ctx[r.sid] = { text: r.text, from: "task", at: r.at }
      else if (r.kind === "prompt") ctx[r.sid] = { text: r.text, from: r.from || "you", at: r.at }
      if (r.kind !== "edit") continue
      ;(editsBy[r.sid] = editsBy[r.sid] || []).push(r)
      events.push({ sid: r.sid, at: r.at, ctx: ctx[r.sid] || { text: "", from: "", at: 0 }, why: r.why || "", whole: !!r.whole, review: r.review || null,
                    files: [{ path: r.path, add: r.add || 0, del: r.del || 0, line: r.line || 1, diff: r.whole ? [] : (r.diff || []) }],
                    key: r.key })
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
        // Only a session that was active shortly before the commit made it; others in the same repo didn't.
        var owner = null, best = cm.at - 7200000
        for (var o of owners) for (var t of (lastSeen[o] || [])) if (t <= cm.at + 60000 && t > best) { best = t; owner = o }
        if (!owner) continue
        var covered = (editsBy[owner] || []).filter(e => e.at > since && e.at <= cm.at + 60000).map(e => e.path)
        var c = ctx[owner]
        for (var q of src) if (q.sid === owner && q.at <= cm.at && (q.kind === "prompt" || (q.kind === "task" && q.action === "switch"))) c = { text: q.text, from: q.kind === "task" ? "task" : q.from || "you", at: q.at }
        events.push({ sid: owner, at: cm.at, ctx: c || { text: "", from: "", at: 0 }, why: cm.subject, commit: true, whole: false,
                      files: cm.files.map(f => { var seen = covered.indexOf(f.path) >= 0
                        return { path: f.path, add: f.add, del: f.del, line: f.line || 1, covered: seen, diff: seen ? [] : f.diff } }),
                      key: "commit:" + cm.hash })
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
        var ed = e.files[0].diff
        pf.diff = pf.diff.concat(pf.diff.length && ed.length ? ["\u22ef"] : []).concat(ed).slice(0, 80)
        prev.at = e.at
        if (!prev.why) prev.why = e.why
        continue
      }
      out.push(e)
    }
    return out.slice(-200)
  }
  // One card per ask: its outcome (the agent's closing line) plus every file it touched.
  readonly property var cards: {
    if (!agentd) return []
    agentd.activityGen
    var marks = agentd.activity.filter(r => r.kind === "summary" || r.kind === "prompt" || (r.kind === "task" && r.action === "switch"))
    var byKey = {}, out = []
    for (var e of changes) {
      var k = "card:" + e.sid + ":" + e.ctx.at + ":" + e.ctx.text
      var c = byKey[k]
      if (!c) { c = byKey[k] = { kind: "card", key: k, sid: e.sid, ctx: e.ctx, at: e.at, changes: [], files: [], outcome: "" }; out.push(c) }
      c.changes.push(e); c.at = Math.max(c.at, e.at)
      for (var f of e.files) {
        if (f.covered) continue
        var g = c.files.find(x => x.path === f.path)
        if (g) { g.add += f.add; g.del += f.del }
        else c.files.push({ path: f.path, add: f.add, del: f.del })
      }
    }
    // An ask answered without edits (the orchestrator's usual work) is still a card.
    for (var m of marks) {
      if (m.kind === "summary") continue
      var ctx = { text: m.text, from: m.kind === "task" ? "task" : m.from || "you", at: m.at }, k = "card:" + m.sid + ":" + m.at + ":" + m.text
      if (!byKey[k]) { byKey[k] = { kind: "card", key: k, sid: m.sid, ctx: ctx, at: m.at, changes: [], files: [], outcome: "" }; out.push(byKey[k]) }
    }
    for (var c of out) {
      var end = Infinity, best = null
      for (var r of marks) if (r.sid === c.sid && r.kind !== "summary" && r.at > c.ctx.at && r.at < end) end = r.at
      for (var r of marks) if (r.sid === c.sid && r.kind === "summary" && r.at >= c.ctx.at && r.at < end && (!best || r.at > best.at)) best = r
      c.outcome = best ? best.text : ""
      c.lead = best && best.lead || ""
      if (best && !c.changes.length) c.at = best.at
      c.jid = c.key + ":" + c.changes.length + ":" + (best ? 1 : 0)
    }
    return out.filter(c => c.changes.length || c.outcome).sort((a, b) => a.at - b.at)
  }
  // Focus never resizes a row: only Enter does.
  // Past days fold to one row so today is what's on screen.
  property var openDays: ({})
  readonly property var rows: {
    var out = [], day = "", sid = "", shown = cards.filter(c => !importantOnly || !minor(c))
    var counts = {}
    for (var c of shown) counts[dayLabel(c.at)] = (counts[dayLabel(c.at)] || 0) + 1
    var lastAt = {}
    for (c of shown) lastAt[dayLabel(c.at) + c.sid] = Math.max(lastAt[dayLabel(c.at) + c.sid] || 0, c.at)
    shown.sort((a, b) => {
      var da = dayLabel(a.at), db = dayLabel(b.at)
      return da !== db ? a.at - b.at : (lastAt[da + a.sid] - lastAt[db + b.sid]) || a.at - b.at
    })
    for (c of shown) {
      var label = dayLabel(c.at), past = label !== "Today"
      if (label !== day) {
        out.push({ kind: past ? "fold" : "day", key: "day:" + label, text: label, count: counts[label], open: !!openDays[label] })
        day = label; sid = ""
      }
      if (past && !openDays[label]) continue
      if (c.sid !== sid) { out.push({ kind: "who", key: "who:" + c.key, sid: c.sid }); sid = c.sid }
      out.push(c)
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
    for (i = rows.length - 1; i >= 0 && !stop(rows[i].kind); i--);
    return i
  }
  readonly property var currentRow: cursor >= 0 ? rows[cursor] : null

  function stop(kind) { return kind === "card" || kind === "fold" }
  // A "Scope: " prefix (commit-subject style) is a label, not the headline.
  function headline(t) {
    var parts = tidy(t).replace(/^[\w./-]+(\s[\w./-]+){0,2}:\s+(?=\S)/, "").split(/(;\s|:\s|\.\s)/)
    var head = parts[0].split(/\s+/).length < 3 && parts.length > 2 ? parts[0] + parts[1] + parts[2] : parts[0]
    return head.replace(/\.$/, "")
  }
  function question(t) {
    var parts = String(t || "").replace(/\s+/g, " ").match(/[^.?!]+[.?!]*/g) || []
    var q = parts.filter(x => /\?\s*$/.test(x)).pop() || parts[0] || ""
    q = q.trim().replace(/^(?:(?:hm+|so|ok(?:ay)?|well|yeah|right|and|but|also)\b[,.]?\s*)+/i, "")
    return q.split(" ").length < 3 ? "" : /^\S*[:\/]/.test(q) ? q : q.charAt(0).toUpperCase() + q.slice(1)
  }
  function sentence(t) { var c = tidy(t); return (c.match(/^.*?[.!?](?=\s|$)/) || [c])[0].replace(/\.$/, "") }
  // Commit hashes in outcomes are for the chat, not for scanning.
  function tidy(t) { return String(t || "").replace(/`/g, "").replace(/\s*\([^()]*\b[0-9a-f]{7,40}\b[^()]*\)/g, "").replace(/\s+([.,;:])/g, "$1").trim() }
  function select(i) {
    cursorKey = rows[i].key
    showRow(i)
  }
  function showRow(i) {
    var last = rows.length - 1
    while (last > i && !stop(rows[last].kind)) last--
    scroller.cursorMoved(i, i === last)
  }
  function move(delta) {
    for (var i = cursor + delta; i >= 0 && i < rows.length; i += delta)
      if (stop(rows[i].kind)) { select(i); return }
  }
  function edge(last) {
    for (var n = 0; n < rows.length; n++) {
      var i = last ? rows.length - 1 - n : n
      if (stop(rows[i].kind)) { select(i); return }
    }
  }
  // Enter folds a past day open or shut, or opens the focused file; returns the next state.
  function open() {
    if (currentRow && currentRow.kind === "fold") {
      var d = Object.assign({}, openDays); d[currentRow.text] = !d[currentRow.text]; openDays = d
    }
    var f = focusFiles[file]
    if (f) fileRequested(currentRow.sid, f.path, f.line)
    return "list"
  }



  ListView {
    id: list
    objectName: "activityList"
    width: Math.min(parent.width - 64, 960)
    height: parent.height
    anchors.horizontalCenter: parent.horizontalCenter
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    model: ListModel { id: rowModel }
    cacheBuffer: 1000000
    ScrollFeel { flick: list; onScrolled: up => scroller.userScrolled(up) }
    onDraggingChanged: dragging ? scroller.gestureStarted() : scroller.gestureEnded()
    header: Item {
      width: list.width; height: root.importantOnly ? 36 : 12
      Text {
        visible: root.importantOnly
        x: 8; anchors.bottom: parent.bottom; anchors.bottomMargin: 6
        text: "Important asks only \u00b7 f shows all"
        color: root.metaColor; font.family: root.bodyFont; font.pixelSize: root.fsMeta - 1
      }
    }

    footer: Item {
      width: list.width; height: root.cards.length ? 72 : 24
      readonly property real newest: root.cards.reduce((n, c) => Math.max(n, c.at), 0)
      Rectangle { visible: endText.visible; anchors.verticalCenter: endText.verticalCenter; x: 8; width: endText.x - 20; height: 1; color: Qt.alpha(Theme.fg, 0.1) }
      Rectangle { visible: endText.visible; anchors.verticalCenter: endText.verticalCenter; x: endText.x + endText.width + 12; width: parent.width - x; height: 1; color: Qt.alpha(Theme.fg, 0.1) }
      Text {
        id: endText
        objectName: "activityEnd"
        visible: root.cards.length > 0
        anchors.horizontalCenter: parent.horizontalCenter; y: 24
        text: "Up to date \u00b7 latest " + root.clock(parent.newest)
        color: root.metaColor; font.family: root.bodyFont; font.pixelSize: root.fsMeta - 1
      }
    }

    delegate: Item {
      id: row
      required property string key
      required property int index
      readonly property var entry: root.rows[index] || ({ kind: "day", files: [], diff: [] })
      readonly property string kind: entry.kind
      readonly property bool current: index === root.cursor && root.focused
      readonly property Item restDot: kind === "fold" ? foldDot : cardDot
      // Focus expands a row (full diff, longer outcome); scroll again once it has its new height.
      onHeightChanged: if (current) Qt.callLater(() => { if (row.current) root.showRow(row.index) })
      width: list.width
      height: kind === "day" ? 52 : kind === "fold" ? 44 : kind === "who" ? 48 : cardBox.height + 2

      CapLabel {
        visible: row.kind === "day"
        anchors { bottom: parent.bottom; bottomMargin: 8; left: parent.left; leftMargin: 8 }
        text: String(row.entry.text || "").toUpperCase()
      }

      Rectangle {
        id: foldBox
        visible: row.kind === "fold"
        y: 6; width: parent.width; height: 34; radius: 10
        color: row.current ? Qt.alpha(Theme.fg, 0.05) : foldHover.hovered ? Qt.alpha(Theme.fg, 0.03) : "transparent"
        border.width: row.current ? 1 : 0
        border.color: root.rail ? root.rail.cardRing : Qt.alpha(Theme.fg, 0.18)
        HoverHandler { id: foldHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: { root.select(row.index); root.forceActiveFocus(); root.send({ type: "tap" }) } }
        Rectangle {
          id: foldDot
          x: 12 - width / 2; anchors.verticalCenter: parent.verticalCenter
          width: 8; height: 8; radius: 4
          color: Theme.cursor
          visible: row.current && !root.caretHeld
        }
        CapLabel {
          x: 24; anchors.verticalCenter: parent.verticalCenter
          text: String(row.entry.text || "").toUpperCase() + "  \u00b7  " + row.entry.count + (row.entry.count === 1 ? " ask" : " asks") + (row.entry.open ? "" : "  \u25b8")
        }
      }

      Row {
        visible: row.kind === "who"
        x: 14; anchors.bottom: parent.bottom; anchors.bottomMargin: 6
        spacing: 10
        Text {
          text: row.entry.sid || ""; textFormat: Text.PlainText
          color: root.contentColor
          font.family: root.bodyFont; font.pixelSize: root.fsName; font.weight: 600
        }
      }

      Rectangle {
        id: cardBox
        visible: row.kind === "card"
        y: 1
        x: 8
        width: parent.width - 8
        height: visible ? cardCol.implicitHeight + 16 : 0
        radius: 12
        readonly property bool dim: root.minor(row.entry)
        readonly property var files: row.entry.files || []
        readonly property var last: (row.entry.changes || []).slice(-1)[0] || ({ why: "" })
        readonly property var ctx: row.entry.ctx || ({ text: "" })
        readonly property string asked: !ctx.text ? "" : ctx.from === "task" ? ctx.text
          : (ctx.from && ctx.from !== "you" ? ctx.from + ": " : "") + "\u201c" + ctx.text + "\u201d"
        readonly property var review: (row.entry.changes || []).reduce((v, e) => e.review || v, null)
        readonly property string relay: ctx.from && ctx.from !== "you" && ctx.from !== "task" ? ctx.from : ""
        readonly property string question: files.length || review || relay ? "" : root.question(ctx.text)
        readonly property string answer: question && row.entry.lead ? root.sentence(row.entry.lead) : ""
        readonly property var glance: row.kind === "card" && !review ? root.snippet(row.entry) : null
        readonly property string done: root.headline(row.entry.outcome || last.why)
        color: row.current ? Qt.alpha(Theme.fg, 0.05) : cardHover.hovered ? Qt.alpha(Theme.fg, 0.03) : "transparent"
        border.width: row.current ? 1 : 0
        border.color: root.rail ? root.rail.cardRing : Qt.alpha(Theme.fg, 0.18)
        HoverHandler { id: cardHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: { root.select(row.index); root.forceActiveFocus(); root.send({ type: "tap" }) } }
        Rectangle {
          id: cardDot
          z: 2
          x: 12 - width / 2; y: cardCol.y + cardHead.lineHeight / 2 - height / 2
          width: 8; height: 8; radius: 4
          color: Theme.cursor
          visible: row.current && !root.caretHeld
        }
        Text {
          id: cardMeta
          anchors { right: parent.right; rightMargin: 12; top: parent.top; topMargin: cardCol.y + (cardHead.lineHeight - height) / 2 }
          text: root.clock(row.entry.at || 0)
          color: root.metaColor
          font.family: root.bodyFont; font.pixelSize: root.fsMeta - 1
        }
        Column {
          id: cardCol
          x: 24; y: 8
          width: parent.width - 36 - cardMeta.width - 12
          spacing: 6
          Text {
            id: cardHead
            objectName: "cardHead"
            width: parent.width
            text: cardBox.review ? '<font color="' + root.metaColor + '">#' + cardBox.review.pr + "</font>&nbsp;&nbsp;" + root.esc(cardBox.review.title || "Review")
              : root.esc(cardBox.answer || cardBox.relay && !cardBox.files.length && row.entry.lead && root.tidy(row.entry.lead).replace(/\.$/, "") || cardBox.done || cardBox.asked)
            leftPadding: relayChip.visible ? relayChip.width + 8 : 0
            PillSurface {
              id: relayChip
              objectName: "relayChip"
              visible: cardBox.relay !== ""
              y: (cardHead.lineHeight - height) / 2
              width: relayText.implicitWidth + 14; height: relayText.implicitHeight + 4; radius: height / 2
              Text {
                id: relayText
                anchors.centerIn: parent
                text: cardBox.relay
                color: root.metaColor; font.family: root.bodyFont; font.pixelSize: root.fsMeta - 3
              }
            }
            textFormat: Text.StyledText
            wrapMode: Text.Wrap; maximumLineCount: 1; elide: Text.ElideRight
            lineHeightMode: Text.FixedHeight; lineHeight: root.fsBody * 1.4
            color: root.contentColor
            font.family: root.bodyFont; font.pixelSize: root.fsBody
          }
          Text {
            width: parent.width
            visible: cardBox.answer !== ""
            text: cardBox.question
            textFormat: Text.PlainText
            elide: Text.ElideRight; maximumLineCount: 1
            color: root.metaColor
            font.family: root.bodyFont; font.pixelSize: root.fsMeta - 1
          }
          Row {
            objectName: "reviewRow"
            visible: !!cardBox.review
            width: parent.width
            spacing: 10
            readonly property var r: cardBox.review || ({ verdict: "", why: "", blocker: 0, should: 0, nit: 0 })
            readonly property color tone: r.verdict === "approve" ? Theme.green : r.verdict === "request-changes" ? Theme.red : Theme.yellow
            Rectangle {
              visible: parent.r.verdict !== ""
              anchors.verticalCenter: parent.verticalCenter
              width: verdictText.implicitWidth + 16; height: verdictText.implicitHeight + 6
              radius: height / 2
              color: Qt.alpha(parent.tone, 0.14)
              Text {
                id: verdictText
                anchors.centerIn: parent
                text: ({ "approve": "Approve", "request-changes": "Changes requested", "comment": "Comment" })[parent.parent.r.verdict] || ""
                color: parent.parent.tone
                font.family: root.bodyFont; font.pixelSize: root.fsMeta - 2; font.weight: Font.DemiBold
              }
            }
            Text {
              id: findingsText
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.StyledText
              text: { var r = parent.r, parts = []
                if (r.blocker) parts.push('<font color="' + Theme.red + '">' + r.blocker + (r.blocker === 1 ? " blocker" : " blockers") + "</font>")
                if (r.should) parts.push(r.should + " should-fix")
                if (r.nit) parts.push(r.nit + (r.nit === 1 ? " nit" : " nits"))
                return parts.length ? parts.join(" \u00b7 ") : "No findings" }
              color: root.contentColor
              font.family: root.bodyFont; font.pixelSize: root.fsMeta - 1
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - x
              text: parent.r.why; textFormat: Text.PlainText
              elide: Text.ElideRight; maximumLineCount: 1
              color: root.metaColor
              font.family: root.bodyFont; font.pixelSize: root.fsMeta - 1
            }
          }
          Rectangle {
            id: glanceBox
            width: parent.width
            visible: !cardBox.dim && !!cardBox.glance
            height: visible ? glanceCol.implicitHeight + 14 : 0
            radius: 10
            objectName: "glanceBox"
            color: root.rail ? root.rail.codePanelColor : Qt.alpha(Theme.fg, 0.05)
            border.width: 1; border.color: Qt.alpha(Theme.fg, 0.07)
            clip: true
            Column {
              id: glanceCol
              y: 7
              width: parent.width
              Repeater {
                model: cardBox.glance ? cardBox.glance.files : []
                delegate: Column {
                  id: gFile
                  required property var modelData
                  required property int index
                  readonly property bool picked: index === (row.current ? root.file : 0)
                  readonly property string language: root.rail ? root.rail.codeLanguage(modelData.path) : ""
                  width: glanceCol.width
                  Item {
                    x: 6; width: parent.width - 12; height: 22
                    Rectangle {
                      visible: row.current && gFile.picked
                      anchors.fill: parent; radius: 6
                      color: Qt.alpha(Theme.fg, 0.07)
                      Rectangle { width: 3; height: parent.height - 8; radius: 1.5; x: 1; anchors.verticalCenter: parent.verticalCenter; color: Theme.cursor }
                    }
                    TapHandler { onTapped: { root.select(row.index); root.file = gFile.index; root.forceActiveFocus(); root.send({ type: "tap" }) } }
                    Icon { id: gIcon; x: 6; name: "file-content"; width: 11; height: 11; color: "#9A6500"; anchors.verticalCenter: parent.verticalCenter }
                    Text {
                      id: gName
                      anchors { left: gIcon.right; leftMargin: 6; verticalCenter: parent.verticalCenter }
                      text: modelData.name; textFormat: Text.PlainText
                      color: Theme.fg_secondary; font.family: Theme.fontFamily; font.pixelSize: root.fsMeta - 3
                    }
                    Text {
                      anchors { left: gName.right; leftMargin: 12; right: gCounts.left; rightMargin: 12; verticalCenter: parent.verticalCenter }
                      text: modelData.why; textFormat: Text.PlainText
                      elide: Text.ElideRight; maximumLineCount: 1
                      color: root.metaColor; font.family: root.bodyFont; font.pixelSize: root.fsMeta - 2
                    }
                    Row {
                      id: gCounts
                      anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
                      spacing: 8
                      Text { visible: modelData.add > 0; text: "+" + modelData.add; color: Theme.green; font.family: Theme.fontFamily; font.pixelSize: root.fsMeta - 3 }
                      Text { visible: modelData.del > 0; text: "\u2212" + modelData.del; color: Theme.red; font.family: Theme.fontFamily; font.pixelSize: root.fsMeta - 3 }
                    }
                  }
                  // Every file's snippet gets the card's tallest height, so moving between files never resizes the card.
                  Column {
                    visible: gFile.picked
                    width: glanceCol.width
                    height: visible ? cardBox.glance.rows * (root.fsMeta - 2) * 1.65 : 0
                    Repeater {
                      model: gFile.modelData.lines
                      delegate: Rectangle {
                        required property var modelData
                        width: glanceCol.width
                        height: (root.fsMeta - 2) * 1.65
                        color: "transparent"
                        Rectangle { x: 1; width: 2; height: parent.height; color: modelData.sign === "-" ? Theme.red : Theme.green }
                        Text {
                          x: 12; width: parent.width - 24
                          anchors.verticalCenter: parent.verticalCenter
                          textFormat: Text.StyledText
                          text: root.rail ? root.rail.highlightCode(modelData.text, gFile.language) : root.esc(modelData.text)
                          elide: Text.ElideRight; maximumLineCount: 1
                          color: Theme.fg
                          font.family: Theme.fontFamily; font.pixelSize: root.fsMeta - 2
                        }
                      }
                    }
                    Text {
                      x: 12
                      visible: gFile.modelData.moreLines > 0
                      height: (root.fsMeta - 2) * 1.65; verticalAlignment: Text.AlignVCenter
                      text: "\u22ef " + gFile.modelData.moreLines + (gFile.modelData.removedList ? " more removed" : " more lines")
                      color: root.metaColor; font.family: root.bodyFont; font.pixelSize: root.fsMeta - 3
                    }
                  }
                }
              }
              Text {
                x: 12
                visible: !!cardBox.glance && cardBox.glance.more > 0
                text: cardBox.glance ? "and " + cardBox.glance.more + " more " + (cardBox.glance.more === 1 ? "file" : "files") : ""
                color: root.metaColor; font.family: root.bodyFont; font.pixelSize: root.fsMeta - 3
                topPadding: 2
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
}

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
  signal yanked(string text)

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

  // Inside a change with several files: which file j/k, Enter and h/l act on; -1 = not inside.
  property int itemIndex: -1
  onCursorKeyChanged: { itemIndex = -1; codeFile = -1 }

  // A vim cursor inside the focused change's code: codeFile is the file it is in, -1 = not in code.
  property int codeFile: -1
  property int codeLine: 0
  property int codeCol: 0
  property string visMode: ""
  property int visLine: 0
  property int visCol: 0
  property string pending: ""
  onCodeFileChanged: { visMode = ""; pending = "" }
  function codeRows() {
    var f = currentRow && codeFile >= 0 ? currentRow.files[codeFile] : null, out = [], last = 0
    for (var l of f ? f.diff : []) {
      var m = l.match(/^([+\- ])\s*(\d*)\s?(.*)$/)
      if (m && m[2]) last = +m[2]
      out.push({ text: l === "\u22ef" || !m ? "" : m[3].replace(/\t/g, "    "), line: m && m[2] ? +m[2] : last + 1 })
    }
    return out
  }
  function enterCode(fi) {
    codeFile = fi
    var rs = codeRows(), first = currentRow.files[fi].diff.findIndex(l => /^[+-]/.test(l))
    codeLine = Math.max(0, first)
    codeCol = Math.max(0, (rs[codeLine] || { text: "" }).text.search(/\S/))
  }
  function selRange(i) {
    if (!visMode) return null
    var a = { l: visLine, c: visCol }, b = { l: codeLine, c: codeCol }
    if (a.l > b.l || (a.l === b.l && a.c > b.c)) { var t = a; a = b; b = t }
    if (i < a.l || i > b.l) return null
    if (visMode === "V") return [0, Infinity]
    return [i === a.l ? a.c : 0, i === b.l ? b.c + 1 : Infinity]
  }
  function keyCode(event) {
    var rs = codeRows(), k = event.key, shift = event.modifiers & Qt.ShiftModifier, p = { l: codeLine, c: codeCol }
    var len = l => rs[l].text.length
    var ch = q => q.c < len(q.l) ? rs[q.l].text[q.c] : "\n"
    var cls = c => /\s/.test(c) ? 0 : /\w/.test(c) ? 1 : 2
    var next = q => q.c < len(q.l) ? { l: q.l, c: q.c + 1 } : q.l < rs.length - 1 ? { l: q.l + 1, c: 0 } : null
    var prev = q => q.c > 0 ? { l: q.l, c: q.c - 1 } : q.l > 0 ? { l: q.l - 1, c: len(q.l - 1) } : null
    var was = pending
    pending = ""
    if (k === Qt.Key_Escape) { if (visMode) visMode = ""; else codeFile = -1; return true }
    if (k === Qt.Key_Return || k === Qt.Key_Enter) { fileRequested(currentRow.sid, currentRow.files[codeFile].path, rs[codeLine].line); return true }
    if (k === Qt.Key_G && !shift && was !== "g") { pending = "g"; return true }
    if (k === Qt.Key_Y && !visMode && was !== "y") { pending = "y"; return true }
    if (k === Qt.Key_Y) {
      var out = []
      for (var i = 0; i < rs.length; i++) {
        var r = visMode ? selRange(i) : i === codeLine ? [0, Infinity] : null
        if (r) out.push(rs[i].text.slice(r[0], r[1]))
      }
      yanked(out.join("\n"))
      if (visMode) { codeLine = Math.min(visLine, codeLine); visMode = "" }
      return true
    }
    if (k === Qt.Key_V) {
      var mode = shift ? "V" : "v"
      if (visMode === mode) visMode = ""
      else { if (!visMode) { visLine = codeLine; visCol = codeCol }; visMode = mode }
      return true
    }
    if (event.modifiers & Qt.ControlModifier) {
      if (k !== Qt.Key_D && k !== Qt.Key_U) return false
      p.l += (k === Qt.Key_D ? 1 : -1) * Math.max(1, Math.floor(height / (2 * fsMeta * 1.5)))
    } else if (k === Qt.Key_H || k === Qt.Key_Left) p.c--
    else if (k === Qt.Key_L || k === Qt.Key_Right) p.c++
    else if (k === Qt.Key_J || k === Qt.Key_Down) p.l++
    else if (k === Qt.Key_K || k === Qt.Key_Up) p.l--
    else if (k === Qt.Key_0) p.c = 0
    else if (k === Qt.Key_AsciiCircum) p.c = Math.max(0, rs[p.l].text.search(/\S/))
    else if (k === Qt.Key_Dollar) p.c = Infinity
    else if (k === Qt.Key_G) p = shift ? { l: rs.length - 1, c: 0 } : { l: 0, c: 0 }
    else if (k === Qt.Key_W) {
      var c0 = cls(ch(p)), q = p
      while (q && c0 && cls(ch(q)) === c0) q = next(q)
      while (q && cls(ch(q)) === 0) q = next(q)
      if (q) p = q
    } else if (k === Qt.Key_E) {
      var q = next(p)
      while (q && cls(ch(q)) === 0) q = next(q)
      if (q) { var c1 = cls(ch(q)); for (var n = next(q); n && cls(ch(n)) === c1; n = next(n)) q = n; p = q }
    } else if (k === Qt.Key_B) {
      var q = prev(p)
      while (q && cls(ch(q)) === 0) q = prev(q)
      if (q) { var c2 = cls(ch(q)); for (var n = prev(q); n && cls(ch(n)) === c2; n = prev(n)) q = n; p = q }
    } else return true
    codeLine = Math.max(0, Math.min(rs.length - 1, p.l))
    codeCol = Math.max(0, Math.min(len(codeLine) - 1, p.c))
    return true
  }
  function keyItem(event) {
    var n = currentRow ? currentRow.files.length : 0
    if (event.key === Qt.Key_Escape) itemIndex = -1
    else if (event.key === Qt.Key_J || event.key === Qt.Key_Down) itemIndex = Math.min(n - 1, itemIndex + 1)
    else if (event.key === Qt.Key_K || event.key === Qt.Key_Up) itemIndex = Math.max(0, itemIndex - 1)
    else if (event.key === Qt.Key_H || event.key === Qt.Key_L) codeShift(event.key === Qt.Key_L ? 1 : -1)
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) open()
    else { itemIndex = -1; return false }
    return true
  }
  Keys.onPressed: event => {
    if (codeFile >= 0 && keyCode(event)) { event.accepted = true; return }
    if (itemIndex >= 0 && keyItem(event)) { event.accepted = true; return }
    var ctrl = event.modifiers & Qt.ControlModifier
    if (ctrl && event.key === Qt.Key_L) focusRequested("right")
    else if (ctrl && event.key === Qt.Key_H) focusRequested("left")
    else if (event.key === Qt.Key_J || event.key === Qt.Key_Down) move(1)
    else if (event.key === Qt.Key_K || event.key === Qt.Key_Up) move(-1)
    else if (event.key === Qt.Key_H || event.key === Qt.Key_L) codeShift(event.key === Qt.Key_L ? 1 : -1)
    else if (event.key === Qt.Key_G) edge(event.modifiers & Qt.ShiftModifier)
    else if (event.key === Qt.Key_S) { if (currentRow) sessionRequested(currentRow.sid) }
    else if (event.key === Qt.Key_F) importantOnly = !importantOnly
    else if (event.key === Qt.Key_Escape && openKey) { var k = openKey; openKey = ""; cursorKey = k }
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) open()
    else return
    event.accepted = true
  }
  signal codeShift(int dir)
  FontMetrics { id: codeMetrics; font.family: Theme.fontFamily; font.pixelSize: root.fsMeta - 2 }
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
        if (!file) files.push(file = { path: f.path, name: String(f.path).split("/").pop(), add: 0, del: 0, why: "", best: null, removed: [], test: isTest(f.path) })
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
    var top = files[0].best, gone = top && top.lines.every(l => l.sign === "-") && files[0].removed.length
    if (gone) top = { lines: files[0].removed.map(l => Object.assign({}, l, { text: l.text.trim().replace(/\s*[{:=]\s*$/, "") })) }
    var lines = top ? top.lines.slice(0, 5) : []
    var indent = lines.length ? Math.min(...lines.map(l => l.text.search(/\S|$/))) : 0
    return { files: files.slice(0, 4), more: files.length - 4, path: files[0].path,
             lines: lines.map(l => Object.assign({}, l, { text: l.text.slice(indent) })),
             moreLines: top ? top.lines.length - lines.length : 0, removedList: !!gone }
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
        prev.edits = (prev.edits || 1) + 1; prev.at = e.at
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
      if (best && !c.changes.length) c.at = best.at
      c.jid = c.key + ":" + c.changes.length + ":" + (best ? 1 : 0)
    }
    return out.filter(c => c.changes.length || c.outcome).sort((a, b) => a.at - b.at)
  }
  property string openKey: ""
  // Focus never resizes a row: only Enter does.
  // Past days fold to one row so today is what's on screen.
  property var openDays: ({})
  readonly property var rows: {
    var out = [], day = "", sid = "", shown = cards.filter(c => !importantOnly || !minor(c) || c.key === openKey)
    var counts = {}
    for (var c of shown) counts[dayLabel(c.at)] = (counts[dayLabel(c.at)] || 0) + 1
    for (c of shown) {
      var label = dayLabel(c.at), past = label !== "Today"
      if (label !== day) {
        out.push({ kind: past ? "fold" : "day", key: "day:" + label, text: label, count: counts[label], open: !!openDays[label] })
        day = label; sid = ""
      }
      if (past && !openDays[label]) continue
      if (c.sid !== sid) { out.push({ kind: "who", key: "who:" + c.key, sid: c.sid }); sid = c.sid }
      out.push(c)
      if (c.key === openKey) for (var e of c.changes) out.push(Object.assign({ kind: "change" }, e))
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

  function stop(kind) { return kind === "card" || kind === "change" || kind === "fold" }
  // A "Scope: " prefix (commit-subject style) is a label, not the headline.
  function headline(t) { return tidy(t).replace(/^[\w./-]+(\s[\w./-]+){0,2}:\s+(?=\S)/, "").split(/;\s|:\s|\.\s/)[0].replace(/\.$/, "") }
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
  function open(byClick) {
    if (currentRow && currentRow.kind === "fold") {
      var d = Object.assign({}, openDays); d[currentRow.text] = !d[currentRow.text]; openDays = d
      return
    }
    if (currentRow && currentRow.kind === "card") {
      openKey = currentRow.key
      var i = rows.findIndex(r => r.key === openKey) + 1
      if (rows[i] && rows[i].kind === "change") select(i)
      return
    }
    if (!currentRow || currentRow.kind !== "change") return
    var files = currentRow.files
    if (itemIndex < 0 && files.length > 1) { itemIndex = Math.max(0, files.findIndex(x => !x.covered)); return }
    var f = itemIndex >= 0 ? files[itemIndex] : files.find(x => !x.covered) || files[0]
    if (f.diff.length && !byClick) { enterCode(files.indexOf(f)); return }
    fileRequested(currentRow.sid, f.path, f.line || 1)
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
    header: Item {
      width: list.width; height: root.importantOnly ? 36 : 12
      Text {
        visible: root.importantOnly
        x: 8; anchors.bottom: parent.bottom; anchors.bottomMargin: 6
        text: "Important asks only \u00b7 f shows all"
        color: root.metaColor; font.family: root.bodyFont; font.pixelSize: root.fsMeta - 1
      }
    }

    footer: Item { height: 24 }

    delegate: Item {
      id: row
      required property string key
      required property int index
      readonly property var entry: root.rows[index] || ({ kind: "day", files: [], diff: [] })
      readonly property string kind: entry.kind
      readonly property bool current: index === root.cursor && root.focused
      readonly property Item restDot: kind === "card" ? cardDot : kind === "fold" ? foldDot : cursorDot
      // Focus expands a row (full diff, longer outcome); scroll again once it has its new height.
      onHeightChanged: if (current && root.codeFile < 0) Qt.callLater(() => { if (row.current) root.showRow(row.index) })
      width: list.width
      height: kind === "day" ? 52 : kind === "fold" ? 44 : kind === "who" ? 48 : kind === "card" ? cardBox.height + 2 : changeBox.height + 6

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
        TapHandler { onTapped: { root.select(row.index); root.forceActiveFocus(); root.open() } }
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
        readonly property bool open: root.openKey === row.key
        readonly property bool dim: root.minor(row.entry) && !open
        readonly property var files: row.entry.files || []
        readonly property var last: (row.entry.changes || []).slice(-1)[0] || ({ why: "" })
        readonly property var ctx: row.entry.ctx || ({ text: "" })
        readonly property string asked: !ctx.text ? "" : ctx.from === "task" ? ctx.text
          : (ctx.from && ctx.from !== "you" ? ctx.from + ": " : "") + "\u201c" + ctx.text + "\u201d"
        readonly property var review: (row.entry.changes || []).reduce((v, e) => e.review || v, null)
        readonly property var glance: row.kind === "card" && !review ? root.snippet(row.entry) : null
        readonly property string done: open ? root.tidy(row.entry.outcome || last.why) : root.headline(row.entry.outcome || last.why)
        opacity: dim ? 0.5 : 1
        color: row.current ? Qt.alpha(Theme.fg, 0.05) : cardHover.hovered ? Qt.alpha(Theme.fg, 0.03) : "transparent"
        border.width: row.current ? 1 : 0
        border.color: root.rail ? root.rail.cardRing : Qt.alpha(Theme.fg, 0.18)
        HoverHandler { id: cardHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: { root.select(row.index); root.forceActiveFocus(); root.open() } }
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
            width: parent.width
            text: cardBox.review ? '<font color="' + root.metaColor + '">#' + cardBox.review.pr + "</font>&nbsp;&nbsp;" + root.esc(cardBox.review.title || "Review")
              : root.esc(cardBox.done || cardBox.asked)
            textFormat: Text.StyledText
            wrapMode: Text.Wrap; maximumLineCount: cardBox.open ? 8 : 1; elide: Text.ElideRight
            lineHeightMode: Text.FixedHeight; lineHeight: root.fsBody * 1.4
            color: root.contentColor
            font.family: root.bodyFont; font.pixelSize: root.fsBody
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
            visible: !cardBox.dim && !cardBox.open && !!cardBox.glance
            height: visible ? glanceCol.implicitHeight + 14 : 0
            radius: 10
            objectName: "glanceBox"
            color: root.rail ? root.rail.codePanelColor : Qt.alpha(Theme.fg, 0.05)
            border.width: 1; border.color: Qt.alpha(Theme.fg, 0.07)
            clip: true
            readonly property string language: root.rail && cardBox.glance ? root.rail.codeLanguage(cardBox.glance.path) : ""
            Column {
              id: glanceCol
              y: 7
              width: parent.width
              Repeater {
                model: cardBox.glance ? cardBox.glance.files : []
                delegate: Column {
                  required property var modelData
                  required property int index
                  width: glanceCol.width
                  Item {
                    x: 12; width: parent.width - 24; height: 22
                    Icon { id: gIcon; name: "file-content"; width: 11; height: 11; color: "#9A6500"; anchors.verticalCenter: parent.verticalCenter }
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
                      anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                      spacing: 8
                      Text { visible: modelData.add > 0; text: "+" + modelData.add; color: Theme.green; font.family: Theme.fontFamily; font.pixelSize: root.fsMeta - 3 }
                      Text { visible: modelData.del > 0; text: "\u2212" + modelData.del; color: Theme.red; font.family: Theme.fontFamily; font.pixelSize: root.fsMeta - 3 }
                    }
                  }
                  Repeater {
                    model: index === 0 ? cardBox.glance.lines : []
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
                        text: root.rail ? root.rail.highlightCode(modelData.text, glanceBox.language) : root.esc(modelData.text)
                        elide: Text.ElideRight; maximumLineCount: 1
                        color: Theme.fg
                        font.family: Theme.fontFamily; font.pixelSize: root.fsMeta - 2
                      }
                    }
                  }
                  Text {
                    x: 12
                    visible: index === 0 && cardBox.glance.moreLines > 0
                    text: "\u22ef " + cardBox.glance.moreLines + (cardBox.glance.removedList ? " more removed" : " more lines")
                    color: root.metaColor; font.family: root.bodyFont; font.pixelSize: root.fsMeta - 3
                    topPadding: 2; bottomPadding: 4
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
          Text {
            width: parent.width
            visible: cardBox.open && cardBox.done !== "" && cardBox.asked !== ""
            text: cardBox.asked
            textFormat: Text.PlainText
            wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
            color: Theme.fg_secondary
            font.family: root.bodyFont; font.pixelSize: root.fsMeta - 1
          }
          Flow {
            width: parent.width
            visible: cardBox.open && cardBox.files.length > 0
            spacing: 6
            Repeater {
              model: cardBox.open ? cardBox.files.slice(0, 8) : []
              delegate: PillSurface {
                required property var modelData
                height: 22; radius: 11
                width: pillRow.implicitWidth + 18
                Row {
                  id: pillRow
                  x: 9; anchors.verticalCenter: parent.verticalCenter
                  spacing: 6
                  Text { text: String(modelData.path).split("/").pop(); color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: root.fsMeta - 2 }
                  Text { visible: modelData.add > 0; text: "+" + modelData.add; color: Theme.green; font.family: Theme.fontFamily; font.pixelSize: root.fsMeta - 2 }
                  Text { visible: modelData.del > 0; text: "-" + modelData.del; color: Theme.red; font.family: Theme.fontFamily; font.pixelSize: root.fsMeta - 2 }
                }
              }
            }
            Text {
              visible: cardBox.files.length > 8
              height: 22; verticalAlignment: Text.AlignVCenter
              text: "+" + (cardBox.files.length - 8) + " files"
              color: root.metaColor; font.family: root.bodyFont; font.pixelSize: root.fsMeta - 2
            }
          }
        }
      }

      Rectangle {
        id: changeBox
        visible: row.kind === "change"
        x: 32
        width: parent.width - 32
        height: visible ? changeCol.implicitHeight + 14 : 0
        radius: 12
        color: row.current ? Qt.alpha(Theme.fg, 0.05) : changeHover.hovered ? Qt.alpha(Theme.fg, 0.03) : "transparent"
        border.width: row.current ? 1 : 0
        border.color: root.rail ? root.rail.cardRing : Qt.alpha(Theme.fg, 0.18)
        HoverHandler { id: changeHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: { root.select(row.index); root.forceActiveFocus(); root.open(true) } }

        Rectangle {
          id: cursorDot
          z: 2
          x: 12 - width / 2; y: timeText.y + timeText.height / 2 - height / 2
          width: 8; height: 8; radius: 4
          color: Theme.cursor
          visible: row.current && !root.caretHeld
        }
        Text {
          id: timeText
          x: 24; y: changeCol.y + (whyText.visible ? (whyText.lineHeight - height) / 2 : (26 - height) / 2)
          width: 44
          text: root.clock(row.entry.at || 0)
          color: root.metaColor
          font.family: root.bodyFont; font.pixelSize: root.fsMeta - 1
        }
        Column {
          id: changeCol
          x: 78; y: 7
          width: parent.width - 90
          spacing: 6
          Text {
            id: whyText
            visible: !!row.entry.why
            width: parent.width
            text: (row.entry.commit ? "Committed: " : "") + (row.entry.why || "")
            textFormat: Text.PlainText
            color: Theme.fg_secondary
            font.family: root.bodyFont; font.pixelSize: root.fsMeta
            lineHeightMode: Text.FixedHeight; lineHeight: root.fsMeta * 1.45
            wrapMode: Text.Wrap; maximumLineCount: 6; elide: Text.ElideRight
          }
          Repeater {
            model: row.kind === "change" ? row.entry.files : []
            delegate: Column {
              id: fileBlock
              required property var modelData
              required property int index
              readonly property var diff: modelData.diff || []
              readonly property int shown: {
                if (root.codeFile === index) return diff.length
                var left = 40, files = row.entry.files || []
                for (var j = 0; j < index; j++) left -= Math.min(left, (files[j].diff || []).length)
                return Math.min(left, diff.length)
              }
              readonly property string language: root.rail ? root.rail.codeLanguage(modelData.path) : ""
              // hunk-nvim's look: added lines in a hunk that also removed lines are "changed" (yellow sign).
              readonly property var changed: {
                var out = [], start = 0
                for (var i = 0; i <= diff.length; i++) {
                  var c = i < diff.length ? diff[i].charAt(0) : " "
                  if (c === "+" || c === "-") continue
                  var removes = diff.slice(start, i).some(l => l.charAt(0) === "-")
                  for (var k = start; k < i; k++) out[k] = removes
                  start = i + 1
                }
                return out
              }
              readonly property bool picked: row.current && root.itemIndex === index
              onPickedChanged: if (picked) Qt.callLater(() => scroller.revealSpan(fileBlock.mapToItem(list.contentItem, 0, 0).y - 8, fileBlock.height + 16))
              width: changeCol.width
              spacing: 6
              Item {
                width: parent.width
                height: 26
                Rectangle {
                  visible: fileBlock.picked
                  x: filePill.x - 4; y: -4; width: filePill.width + 8; height: parent.height + 8
                  radius: height / 2; color: "transparent"
                  border.width: 1.5; border.color: root.rail ? root.rail.activeRing : Theme.fg
                }
                PillSurface {
                  id: filePill
                  readonly property string rel: root.relPath(row.entry.sid, fileBlock.modelData.path)
                  readonly property int cut: rel.lastIndexOf("/") + 1
                  height: 26; radius: 13
                  width: Math.min(pathText.implicitWidth + 40, parent.width - counts.width - 16)
                  opacity: fileBlock.modelData.covered ? 0.55 : 1
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
                Row {
                  id: counts
                  anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                  spacing: 10
                  Text { text: "+" + fileBlock.modelData.add; color: Theme.green; font.family: Theme.fontFamily; font.pixelSize: root.fsMeta }
                  Text { text: "-" + fileBlock.modelData.del; color: Theme.red; font.family: Theme.fontFamily; font.pixelSize: root.fsMeta }
                }
              }
              Rectangle {
                visible: fileBlock.shown > 0
                width: parent.width
                height: visible ? diffCol.implicitHeight + 12 : 0
                radius: 12
                color: root.rail ? root.rail.codePanelColor : Qt.alpha(Theme.fg, 0.05)
                clip: true
                Flickable {
                  id: codeFlick
                  anchors.fill: parent
                  flickableDirection: Flickable.HorizontalFlick
                  boundsBehavior: Flickable.StopAtBounds
                  contentWidth: Math.max(width, 22 + codeMetrics.advanceWidth("0") * (6 + fileBlock.diff.slice(0, fileBlock.shown)
                    .reduce((n, l) => Math.max(n, l.replace(/^[+\- ]\d*\s?/, "").replace(/\t/g, "    ").length), 0)))
                  contentHeight: height
                  ScrollFeel { flick: codeFlick }
                  readonly property real caretX: row.current && root.codeFile === fileBlock.index ? 10 + (6 + root.codeCol) * codeMetrics.advanceWidth("0") : -1
                  onCaretXChanged: {
                    if (caretX < 0) return
                    codeGlide.stop()
                    if (caretX < contentX + 30) contentX = Math.max(0, caretX - 60)
                    else if (caretX + 30 > contentX + width) contentX = Math.min(contentWidth - width, caretX - width + 60)
                  }
                  NumberAnimation { id: codeGlide; target: codeFlick; property: "contentX"; duration: 120; easing.type: Easing.OutCubic }
                  Connections {
                    target: root
                    enabled: row.current && (root.itemIndex < 0 || root.itemIndex === fileBlock.index)
                    function onCodeShift(dir) {
                      codeGlide.stop()
                      codeGlide.to = Math.max(0, Math.min(codeFlick.contentWidth - codeFlick.width, codeFlick.contentX + dir * codeFlick.width / 2))
                      codeGlide.start()
                    }
                  }
                Column {
                  id: diffCol
                  width: codeFlick.contentWidth
                  y: 6
                  Repeater {
                    model: fileBlock.diff.slice(0, fileBlock.shown)
                    delegate: Rectangle {
                      required property string modelData
                      required property int index
                      readonly property var parts: modelData.match(/^([+\- ])\s*(\d*)\s?(.*)$/) || ["", " ", "", modelData]
                      readonly property string sign: parts[1]
                      width: diffCol.width
                      height: diffLine.implicitHeight + 3
                      color: sign === "-" ? Theme.diffRemovedBg : "transparent"
                      readonly property bool inCode: row.current && root.codeFile === fileBlock.index
                      readonly property bool caretHere: inCode && root.codeLine === index
                      readonly property var sel: inCode ? root.selRange(index) : null
                      readonly property real adv: codeMetrics.advanceWidth("0")
                      onCaretHereChanged: if (caretHere) Qt.callLater(() => { var q = mapToItem(list.contentItem, 0, 0); scroller.revealSpan(q.y - 24, height + 48) })
                      Rectangle {
                        visible: !!parent.sel
                        x: diffLine.x + 6 * parent.adv + (parent.sel ? parent.sel[0] : 0) * parent.adv
                        width: parent.sel ? Math.max(parent.adv, (Math.min(parent.sel[1], diffLine.text === "\u22ef" ? 0 : parent.parts[3].replace(/\t/g, "    ").length) - parent.sel[0]) * parent.adv) : 0
                        height: parent.height
                        color: Qt.alpha(Theme.cursor, 0.25)
                      }
                      Rectangle {
                        visible: parent.caretHere
                        x: diffLine.x + (6 + root.codeCol) * parent.adv
                        width: parent.adv; height: parent.height
                        color: Qt.alpha(Theme.cursor, 0.6)
                      }
                      Rectangle { width: 2; height: parent.height; visible: parent.sign === "+"; color: fileBlock.changed[parent.index] ? Theme.yellow : Theme.green }
                      Text {
                        id: diffLine
                        x: 10; width: parent.width - 16
                        anchors.bottom: parent.bottom; anchors.bottomMargin: 1
                        textFormat: Text.StyledText
                        text: modelData === "\u22ef" ? "\u22ef"
                          : '<font color="' + Qt.alpha(Theme.fg_muted, 0.75) + '">' + ("    " + (sign === "-" ? "" : parts[2])).slice(-4).replace(/ /g, "&nbsp;") + "&nbsp;&nbsp;</font>"
                            + (sign === "-" ? '<font color="' + Theme.red + '">' + root.esc(parts[3]).replace(/\t/g, "    ").replace(/ /g, "&nbsp;") + "</font>"
                              : root.rail ? root.rail.highlightCode(parts[3], fileBlock.language) : root.esc(parts[3]))
                              .replace(/^[ \t]+/, ws => ws.replace(/\t/g, "    ").replace(/ /g, "&nbsp;"))
                        color: modelData === "\u22ef" ? root.metaColor : Theme.fg
                        font.family: Theme.fontFamily
                        font.pixelSize: root.fsMeta - 2
                        wrapMode: Text.NoWrap; maximumLineCount: 1
                      }
                    }
                  }
                }
                }
              }
              Text {
                readonly property int hidden: fileBlock.diff.length - fileBlock.shown
                readonly property bool inCode: root.codeFile === fileBlock.index
                visible: fileBlock.diff.length > 0 && (inCode || root.codeFile < 0) && (root.itemIndex < 0 || fileBlock.picked)
                x: 10
                text: inCode ? (root.visMode ? (root.visMode === "V" ? "VISUAL LINE" : "VISUAL") + " \u00b7 y yanks \u00b7 Esc" : "hjkl w b e 0 ^ $ gg G \u00b7 v V y yy \u00b7 Enter opens this line \u00b7 Esc leaves")
                  : (hidden > 0 ? "\u2026 " + hidden + " more lines \u00b7 " : "") + (root.itemIndex < 0 && row.entry.files.length > 1 ? "Enter picks a file" : "Enter steps into the code")
                color: root.metaColor; font.family: root.bodyFont; font.pixelSize: root.fsMeta - 1
              }
            }
          }
          Text {
            visible: row.entry.whole === true
            text: ((row.entry.files || []).length > 1 ? "Wrote " + row.entry.files.length + " new files" : "Wrote the whole file") + " \u00b7 Enter opens it"
            color: root.metaColor
            font.family: root.bodyFont; font.pixelSize: root.fsMeta - 1
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

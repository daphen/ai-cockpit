import QtQuick
import QtQuick.Effects
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import QsLib

// The agent rail: roster (from agentd) + activity feed + composer.
// Vim nav (dsqrd model): j/k move the roster cursor, Enter selects the session
// (drives feed + composer target), i enters the composer, Esc/Ctrl+h/h leave to nvim.
Item {
  id: rail
  // The roster sheet bleeds 1px past both sides (and one radius above) to hide its
  // rounded corners + side hairlines; without clipping that bleed renders next to
  // the term/rail divider as a double line.
  clip: true

  property var agentd: null
  property string scopeMode: "personal"
  property string instanceName: "main"
  signal requestScopeMode(string mode)
  Shortcut {
    sequence: "Ctrl+S"
    context: Qt.ApplicationShortcut
    onActivated: rail.requestScopeMode(rail.scopeMode === "work" ? "personal" : "work")
  }
  // Set by shell.qml from TermView.nvimSocket — the socket THIS instance's nvim listens
  // on. Never rebuild this path here: a guessed shared name is how the rail ended up
  // talking to a socket a newer Cockpit had already unlinked.
  property string nvimSock: ""
  property bool focused: false
  signal focusNvim()
  signal requestFocus()   // a click in the rail should pull focus here

  function cockpitEnv(name) {
    return Quickshell.env("COCKPIT_" + name) || Quickshell.env("HEIDR_" + name)
  }

  // Click a row: focus the rail, move the cursor there, and act on it.
  function clickAt(idx) { _blurFeedKey = ""; requestFocus(); cur = idx; activateCur() }
  // Pull focus to the rail and land on the roster (Super+T from the desktop).
  // Super+T must work from ANYWHERE, including while typing: the composer holds the
  // keyboard in insert mode, so moving `cur` alone did nothing visible. Leave insert
  // and clear the restore flag, or the next focus change would drop you back into it.
  // Jump straight to a session by name (Super+i on a live question): select it
  // and put the keyboard in the rail so the ask card's keys work immediately.
  function jumpToSession(n) {
    if (!n) return
    activeRaw = n
    rosterOverride = false
    requestFocus()
  }
  function focusRoster() {
    if (rosterOverride === false) rosterOverride = true
    exitInsert()
    _wasInsert = false
    _blurFeedKey = ""   // explicit roster jump beats the blur-position restore
    // Land on the ACTIVE session's row, not row 0 — Super+T means "show me where I am",
    // and the top row was usually somebody else.
    var i = _rosterIndexOf(selectedRaw)
    cur = i >= 0 ? i : 0
    requestFocus()
  }

  // Cursor flows: roster (always) → the main area, whose view Tab toggles.
  property int cur: 0
  property string view: "chat"   // main area below the roster: "chat" | "files"
  readonly property int rSize: rosterList.length
  readonly property int cSize: changesList.length
  readonly property int fSize: groupedFeed.length
  readonly property int viewSize: view === "files" ? cSize : fSize
  readonly property int navTotal: rSize + viewSize
  function curSection() { return cur < rSize ? "roster" : view }
  function curLocal()   { return cur < rSize ? cur : cur - rSize }

  // Reconciled roster model. `rosterList` is a fresh JS ARRAY on every daemon event, and a
  // Repeater cannot diff an array — it destroys and rebuilds every row, which restarts each
  // row's ThinkingOrb canvas and its rotation animation, so a streaming session's spinner visibly
  // blinked on every roster tick. Same fix as the feed: reconcile by signature so the
  // delegates persist and only a row that really changed is written.
  ListModel { id: rosterModel; dynamicRoles: true }
  // KEYED reconcile, shared by the roster and the feed. Index-based reconciling
  // couldn't survive a transient row-count dip (a mid-stream regroup, a session
  // removal): the tail — usually the LIVE row — was destroyed and re-created a
  // beat later, which is a blink. Matching by identity instead means insertions
  // and removals touch exactly the rows that appeared or vanished.
  function _reconcileKeyed(model, arr, keyOf, sigOf) {
    var want = {}
    for (var a = 0; a < arr.length; a++) want[keyOf(arr[a])] = true
    for (var r = model.count - 1; r >= 0; r--)
      if (!want[model.get(r).k]) model.remove(r)
    for (var i = 0; i < arr.length; i++) {
      var k = keyOf(arr[i]), sig = sigOf(arr[i])
      if (i < model.count && model.get(i).k === k) {
        if (model.get(i).sig !== sig) {
          model.setProperty(i, "d", arr[i])
          model.setProperty(i, "sig", sig)
        }
        continue
      }
      // not at i: either it exists later (a row above it vanished — already handled
      // by the removal pass) or it is new. Find it; move is rare (stable orders).
      var found = -1
      for (var j = i + 1; j < model.count; j++) if (model.get(j).k === k) { found = j; break }
      if (found >= 0) model.move(found, i, 1)
      else model.insert(i, { d: arr[i], sig: sig, k: k })
      if (model.get(i).sig !== sig || found >= 0) {
        model.setProperty(i, "d", arr[i])
        model.setProperty(i, "sig", sig)
      }
    }
  }
  function _rosterSig(x) {
    if (!x) return ""
    return [x.name, x.rawName, x.status, x.idle, x.remote === true, x.devenv === true,
            x.depth || 0, x.linked === true, x.profile || x.role || ""].join("|")
  }
  function syncRosterModel() {
    _reconcileKeyed(rosterModel, rosterList || [],
                    function (x) { return String(x.rawName || x.name || "") },
                    _rosterSig)
  }
  Component.onCompleted: syncRosterModel()

  // The roster cursor is anchored to a session's IDENTITY, not its row number. Rows are
  // name-sorted, but a session appearing or going offline still shifts every index below
  // it, so a bare index quietly slides onto a different session between rebuilds — which
  // is how `x` once closed the wrong one. Re-derive the index after every rebuild.
  // The same holds for a feed row: the transcript is capped to its last 60 messages, so
  // in a long session every new message slides that window and shifts every row's index.
  property string cursorName: ""
  property string cursorFeedKey: ""
  readonly property string cursorKey: cur < rSize ? ("r:" + cursorName) : ("f:" + cursorFeedKey)
  function _rosterIndexOf(n) {
    if (!n) return -1
    for (var i = 0; i < rosterList.length; i++)
      if ((rosterList[i].rawName || rosterList[i].name) === n) return i
    return -1
  }
  function _feedIndexOf(k) {
    if (!k) return -1
    for (var i = 0; i < groupedFeed.length; i++)
      if (groupedFeed[i].key === k) return i
    return -1
  }
  function _anchorCursor() {
    if (cur < rSize) {
      if (rosterList[cur]) cursorName = rosterList[cur].rawName || rosterList[cur].name
    } else if (groupedFeed[cur - rSize]) {
      cursorFeedKey = groupedFeed[cur - rSize].key
    }
  }
  onRosterListChanged: {
    syncRosterModel()
    if (cur >= rSize) return          // cursor is in the feed; roster order can't affect it
    var want = _rosterIndexOf(cursorName)
    if (want >= 0) cur = want
    else { cur = Math.max(0, Math.min(cur, rSize - 1)); _anchorCursor() }
  }
  // Only while READING (free): following wants the newest row, and a session switch is
  // seeking to the end — neither should be dragged back to a stale anchor.
  onGroupedFeedChanged: {
    if (feedScroll.mode !== "free") return
    var i = _feedIndexOf(cursorFeedKey)
    if (_restoring) {
      // Restoring a remembered position: the row may not be in the transcript any more
      // (trimmed, or the session moved on) — then fall back to the newest message rather
      // than leaving the cursor on whatever index it happened to hold.
      if (i >= 0) { cur = rSize + i; _restoring = false }
      else if (groupedFeed.length) { _restoring = false; feedScroll.toEnd() }
      return
    }
    if (cur < rSize) return          // cursor is in the roster; feed order can't affect it
    if (i >= 0 && rSize + i !== cur) cur = rSize + i
  }
  property bool insert: false
  // Chat autoscroll is a state machine (FeedScroll.qml) and the ONLY thing that moves
  // the feed viewport. Callers report events — scrolled, gesture, synced, cursor moved —
  // and it decides. Everything here used to be four booleans arbitrating six writers.
  FeedScroll {
    id: feedScroll
    view: feedView
    chatVisible: rail.view === "chat"
    onWantCursorAtEnd: (force) => {
      // "The end" is the end of the FEED. With no feed rows, navTotal - 1 is the last
      // roster row, and honouring it here is what dropped the cursor onto an unrelated
      // session on every switch.
      if (rail.navTotal <= rail.rSize) return
      if (force || rail.cur >= rail.rSize) rail.cur = rail.navTotal - 1
    }
  }
  property string activeRaw: ""
  property var recentSelections: []
  function rememberRecent(name) {
    if (!name) return
    var next = [name]
    for (var i = 0; i < recentSelections.length; i++)
      if (recentSelections[i] !== name) next.push(recentSelections[i])
    recentSelections = next.slice(0, 20)
  }
  function recentFallback(excluding) {
    for (var i = 0; i < recentSelections.length; i++) {
      var name = recentSelections[i]
      if (name === excluding) continue
      for (var j = 0; j < liveSessions.length; j++)
        if (liveSessions[j].name === name) return name
    }
    for (var k = 0; k < liveSessions.length; k++)
      if (liveSessions[k].name !== excluding && !liveSessions[k].parent) return liveSessions[k].name
    for (var n = 0; n < liveSessions.length; n++)
      if (liveSessions[n].name !== excluding) return liveSessions[n].name
    return ""
  }
  function stopSession(name) {
    var target = String(name || "")
    if (!target || !agentd) return
    if (target === selectedRaw) {
      var fallback = recentFallback(target)
      activeRaw = fallback
      defaultRaw = fallback
    }
    recentSelections = recentSelections.filter(x => x !== target)
    agentd.stop(target)
  }
  // Roster starts expanded and stays however you leave it — Ctrl+t toggles the
  // full list vs the single-row glance, and the choice persists across focus
  // changes (no auto-collapse on blur).
  property var rosterOverride: true   // true = expanded (default), false = collapsed glance
  readonly property bool rosterExpanded: rosterOverride !== null ? rosterOverride : focused

  function copyText(s) {
    if (!s || !s.length) return
    Quickshell.execDetached(["wl-copy", "--", String(s)])
    var t = String(s).replace(/\s+/g, " ").trim()
    feedbackPill.show("✓ copied — " + (t.length > 40 ? t.slice(0, 37) + "…" : t))
  }

  // ── slash commands ─────────────────────────────────────────────────────────
  // The composer advertised "/ for commands" with nothing behind it. pi's command
  // set IS its prompts dir (~/.pi/agent/prompts/<name>.md), so list that once and
  // filter it as you type. Typing the full command has always worked — pi treats a
  // leading-slash prompt as a command — this just makes them discoverable.
  property var commands: []
  readonly property string composerText: composerInput.text
  readonly property bool slashOpen: rail.insert && composerText.charAt(0) === "/" && commandMatches.length > 0
  // Fuzzy subsequence match, ranked: exact prefix first, then earliest-and-tightest
  // run of matched letters. Prefix-only matching meant `/plan` never found
  // `skill:plan-ticket`, and the skills are the long names you least want to type.
  function _fuzzyScore(cand, q) {
    if (!q.length) return 0
    var c = cand.toLowerCase(), i = 0, first = -1, last = -1
    for (var k = 0; k < c.length && i < q.length; k++) {
      if (c[k] === q[i]) { if (first < 0) first = k; last = k; i++ }
    }
    if (i < q.length) return -1                       // not a subsequence
    if (c.indexOf(q) === 0) return 1000               // exact prefix wins outright
    var spread = last - first + 1
    return 500 - first * 4 - (spread - q.length) * 2  // early + tight scores higher
  }
  readonly property var commandMatches: {
    var t = String(composerText || "")
    if (t.charAt(0) !== "/") return []
    if (t.indexOf(" ") >= 0) return []            // already past the command word
    var q = t.slice(1).toLowerCase()
    var scored = []
    for (var i = 0; i < commands.length; i++) {
      var sc = _fuzzyScore(commands[i], q)
      if (sc >= 0) scored.push({ c: commands[i], s: sc, i: i })
    }
    scored.sort((a, b) => b.s - a.s || (a.c.length - b.c.length) || (a.i - b.i))
    return scored.map(x => x.c)
  }
  property int slashCur: 0
  onCommandMatchesChanged: slashCur = 0
  property var fileChoices: []
  property int fileChoiceCur: 0
  property string fileChoiceKey: ""
  readonly property bool fileSelectOpen: fileChoices.length > 0
  function startFileSelection(paths, key) {
    fileChoices = paths.slice()
    fileChoiceCur = 0
    fileChoiceKey = key
  }
  function closeFileSelection() { fileChoices = []; fileChoiceKey = "" }
  function acceptFileChoice() {
    var path = fileChoices[Math.max(0, Math.min(fileChoiceCur, fileChoices.length - 1))]
    closeFileSelection()
    if (path) openFileRef(path)
  }
  function keyFileSelection(e) {
    var ctrl = e.modifiers & Qt.ControlModifier
    if (e.key === Qt.Key_Escape) { closeFileSelection(); return true }
    if (ctrl && (e.key === Qt.Key_Return || e.key === Qt.Key_Enter)) {
      toggleCurBash(); return true
    }
    if (e.key === Qt.Key_J || e.key === Qt.Key_Down || (ctrl && e.key === Qt.Key_N)) {
      fileChoiceCur = (fileChoiceCur + 1) % fileChoices.length; return true
    }
    if (e.key === Qt.Key_K || e.key === Qt.Key_Up || (ctrl && e.key === Qt.Key_P)) {
      fileChoiceCur = (fileChoiceCur - 1 + fileChoices.length) % fileChoices.length; return true
    }
    if (e.key === Qt.Key_O || e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
      acceptFileChoice(); return true
    }
    return true
  }
  // Prefill the composer and take the keyboard: used by the header controls so a click
  // lands you in the same command you would have typed.
  function prefillComposer(text) {
    composerInput.text = text
    composerInput.forceActiveFocus()
    composerInput.cursorPosition = composerInput.text.length
    rail.insert = true
  }

  function acceptSlash() {
    var c = commandMatches[Math.max(0, Math.min(slashCur, commandMatches.length - 1))]
    if (c) composerInput.text = "/" + c + " "
  }
  Process {
    id: cmdList
    running: true
    // Both of pi's command surfaces: prompts (~/.pi/agent/prompts/<name>.md) and
    // EVERY skill as `/skill:<name>`, which is how pi addresses them. Prompts that
    // wrap a skill therefore appear under both spellings — deliberate: the list is
    // for discovery, and a missing skill is worse than a duplicate.
    command: ["sh", "-c",
      "ls ~/.pi/agent/prompts 2>/dev/null | sed 's/\\.md$//'; " +
      "for d in ~/.pi/agent/skills/*/; do [ -d \"$d\" ] && basename \"$d\" | sed 's|^|skill:|'; done"]
    stdout: StdioCollector {
      onStreamFinished: rail.commands = ["goal", "handover"]
        .concat(String(this.text || "").split("\n").filter(s => s.length > 0))
    }
  }

  property bool hinting: false
  property var hintLabels: []
  property var hintTargets: []
  property int hintIdx: -1
  readonly property string hintChars: "asdfghjklqwertyuiopzxcvbnm"
  property bool yankMode: false
  onViewChanged: if (hinting) cancelHints("view")

  function _unitRe() {
    return /```([a-zA-Z0-9_-]*)[ \t]*\n([\s\S]*?)```|`([^`\n]+)`|\[[^\]]*\]\((https?:\/\/[^\s)]+)\)|(https?:\/\/[^\s<>")\]]+)|((?:[\w.@~-]+\/)+[\w.@-]+\.\w{1,6})(:\d+)?/g
  }
  // A repo path the agent named: at least one slash and an extension, so prose
  // ("e.g", "2.21.0") and bare words never match.
  function _fileRe() { return /((?:[\w.@~-]+\/)+[\w.@-]+\.\w{1,6})(:\d+)?/g }
  function _statFor(path) {
    var l = changesList || []
    for (var i = 0; i < l.length; i++) if (l[i].path === path) return l[i]
    if (!l.length) _ensureChanges()
    return null
  }
  function _shellLanguage(lang) {
    return /^(bash|sh|zsh|shell|console)$/.test(String(lang || "").toLowerCase())
  }
  function _scanUnits(text, entryIndex, mode, baseOffset) {
    var re = _unitRe(), m, units = [], source = String(text || ""), base = baseOffset || 0
    while ((m = re.exec(source)) !== null) {
      var kind = m[2] !== undefined ? "fence" : m[3] !== undefined ? "inline"
        : m[6] !== undefined ? "file" : "url"
      // Agents habitually backtick paths; a code span holding nothing but a path is
      // a file reference, not a snippet to yank.
      if (kind === "inline" && /^(?:[\w.@~-]+\/)+[\w.@-]+\.\w{1,6}(?::\d+)?$/.test(String(m[3]).trim()))
        kind = "file"
      var runnable = kind === "fence" && _shellLanguage(m[1])
      if ((mode === "hint" && !(kind === "url" || kind === "file" || runnable)) ||
          (mode === "yank" && !(kind === "url" || kind === "inline" || kind === "fence" || kind === "file"))) continue
      units.push({
        key: "e" + entryIndex + ":p" + (base + m.index),
        kind: runnable ? "shell" : kind,
        value: kind === "fence" ? m[2]
          : kind === "file" ? String(m[6] !== undefined ? (m[6] + (m[7] || "")) : m[3]).trim()
          : kind === "inline" ? m[3] : (m[4] || m[5]),
        start: base + m.index,
        end: base + m.index + m[0].length
      })
    }
    return units
  }
  function _rowUnits(item, mode) {
    var out = []
    if (!item) return out
    if (item.kind === "turn") {
      var prose = turnProse(item.items)
      for (var i = 0; i < prose.length; i++) out = out.concat(_scanUnits(prose[i].text, i, mode, 0))
      if (mode === "hint") {
        var refs = activityFileRefs(item)
        for (var j = 0; j < refs.length; j++) {
          if (!out.some(x => x.kind === "file" && x.value === refs[j]))
            out.push({ key: "edit:" + j, kind: "file", value: refs[j], start: 0, end: 0 })
        }
      }
    } else {
      out = _scanUnits(item.text || "", 0, mode, 0)
      if (mode === "hint") out = out.filter(x => x.kind === "url" || x.kind === "file")
    }
    return out
  }
  function _startHintMode(mode) {
    if (view !== "chat" || cur < rSize) return
    var idx = cur - rSize, chars = mode === "yank" ? hintChars.replace("y", "") : hintChars
    var targets = _rowUnits(groupedFeed[idx], mode).slice(0, chars.length), labels = []
    if (mode === "hint" && !targets.length) return
    for (var i = 0; i < targets.length; i++) {
      labels.push(chars.charAt(i))
      targets[i].label = chars.charAt(i)
    }
    hintTargets = targets; hintLabels = labels; hintIdx = idx; hinting = true; yankMode = mode === "yank"
    if (yankMode) feedbackPill.show(targets.length ? "YANK MODE — pick a cap · yy = all · esc"
                                                   : "YANK MODE — no code/links here · yy = all · esc")
  }
  function startHints() { _startHintMode("hint") }
  function startYank() { _startHintMode("yank") }
  property string lastCancel: ""
  function cancelHints(why) {
    if (hinting) lastCancel = (why || "unknown") + " @cur=" + cur
    hinting = false; yankMode = false; hintLabels = []; hintTargets = []; hintIdx = -1
  }
  function requestSnippet(command) {
    var cmd = String(command || "")
    if (!cmd.length || !agentd || !selectedRaw) return
    cancelHints("snippet")
    agentd.submit(selectedRaw,
      "You MUST invoke request_user_bash for this exact command; do not execute it directly. " +
      "The command is JSON-encoded below—decode it without changing any character:\n\n" + JSON.stringify(cmd))
    feedbackPill.show("approval requested — sent to " + shortName(selectedRaw))
  }
  function hintKey(ch) {
    var i = hintLabels.indexOf(ch), t = i >= 0 ? hintTargets[i] : null
    var wasYank = yankMode, idx = hintIdx
    cancelHints("picked:" + ch)
    if (wasYank) {
      if (t) copyText(t.value)
      else if (ch === "y") copyText(String(feedCopyTarget(groupedFeed[idx]) || ""))
    } else if (t && t.kind === "shell") requestSnippet(t.value)
    else if (t && t.kind === "file") openFileRef(t.value)
    else if (t) Quickshell.execDetached(["xdg-open", t.value])
  }
  function hintForKey(key, rowIdx) {
    if (!hinting || hintIdx !== rowIdx) return null
    for (var i = 0; i < hintTargets.length; i++) if (hintTargets[i].key === key) return hintTargets[i]
    return null
  }
  function firstUrl(text) {
    var units = _scanUnits(text, 0, "hint", 0)
    for (var i = 0; i < units.length; i++) if (units[i].kind === "url") return units[i].value
    return ""
  }
  function openPendingAskUrl() {
    if (!pendingAsk) return false
    var url = firstUrl(String(pendingAsk.title || "") + "\n" + String(pendingAsk.message || pendingAsk.placeholder || ""))
    if (!url.length) return false
    Quickshell.execDetached(["xdg-open", url])
    return true
  }
  // Qt IGNORES Text.linkColor for MarkdownText (links stay the default dark blue,
  // invisible on the dark card), so colour the link's visible text inline instead.
  // Underline is left to the anchor, so links still read as links.
  readonly property string summaryHex: rail._hex(summaryColor)
  function colorizeLinks(t) {
    // A label that LOOKS like a URL gets re-autolinked by Qt inside our colored
    // span (palette dark blue wins over the font tag) — a zero-width space after
    // :// breaks the re-detection, invisibly.
    function safeLabel(x) { return String(x).replace("://", "://\u200B") }
    var out = String(t || "").replace(/\[([^\]]*)\]\((https?:\/\/[^\s)]+)\)/g,
      function (all, label, url) {
        return "[<font color=\"" + rail.summaryHex + "\"><u>" + safeLabel(label) + "</u></font>](" + url + ")"
      })
    // Bare URLs too: Qt autolinks them but paints with the PALETTE link color
    // (near-invisible dark blue on the dark ground), ignoring linkColor — so wrap
    // them into explicit colored markdown links ourselves.
    return out.replace(/(^|[\s])(https?:\/\/[^\s)<>"]+)/g, function (all, pre, url) {
      return pre + "[<font color=\"" + rail.summaryHex + "\"><u>" + safeLabel(url) + "</u></font>](" + url + ")"
    })
  }
  // agentd emits a `changes` diff only at TURN END, so an idle session's rows would
  // show no numbers. Ask for the on-demand local diff instead, mapping the session's
  // cwd through the vm-sync mirror so it works for remote sessions too.
  property var _changesAsked: ({})
  function _ensureChanges() {
    if (!agentd || !selectedRaw || _changesAsked[selectedRaw]) return
    // selectedRaw is a session NAME (see defaultRaw), so match name as well as id —
    // comparing against id alone never matched and the refresh was never asked for.
    var cwd = ""
    for (var i = 0; i < agentd.sessions.length; i++) {
      var ss = agentd.sessions[i]
      if (ss.id === selectedRaw || ss.name === selectedRaw) { cwd = ss.cwd; break }
    }
    if (!cwd) return
    _changesAsked[selectedRaw] = true
    var localCwd = _localPath(cwd)
    agentd.refreshChanges(selectedRaw, localCwd)
  }

  // decorateMarkdown injects hint labels INTO the prose text; a path that became its
  // own row is no longer in that text, so the row has to render its own label.
  function fileHintFor(path, rowIdx) {
    if (!hinting || hintIdx !== rowIdx) return ""
    for (var i = 0; i < hintTargets.length; i++) {
      var t = hintTargets[i]
      if (t.kind !== "file") continue
      if (String(t.value).replace(/:\d+$/, "") === path) return hintLabels[i] || ""
    }
    return ""
  }
  // Own-line file paths in a feed item, for Enter-to-open.
  function fileRefLines(item) {
    if (!item) return []
    var texts = item.kind === "turn" ? turnProse(item.items).map(x => x.text) : [item.text || ""]
    var out = []
    for (var i = 0; i < texts.length; i++) {
      var ls = String(texts[i] || "").split("\n")
      for (var j = 0; j < ls.length; j++) {
        var m = ls[j].trim().match(/^`?((?:\/|~\/)?(?:[\w.@-]+\/)+[\w.@-]+\.\w{1,6})(:\d+)?`?[.,;:]?$/)
        if (m && out.indexOf(m[1]) < 0) out.push(m[1])
      }
    }
    return out
  }
  function activityFileRefs(item) {
    var out = []
    if (!item || item.kind !== "turn") return out
    for (var i = 0; i < (item.items || []).length; i++) {
      var entry = item.items[i], path = entry && entry.kind === "edit" ? String(entry.path || "") : ""
      if (path && out.indexOf(path) < 0) out.push(path)
    }
    return out
  }
  function cardFileRefs(item) {
    var out = fileRefLines(item), edits = activityFileRefs(item)
    for (var i = 0; i < edits.length; i++) if (out.indexOf(edits[i]) < 0) out.push(edits[i])
    return out
  }
  function shownFileRef(ref) {
    var r = String(ref || "")
    return /^(inbox|journal|meetings|memory|plans|references|reviews)\//.test(r) ? "/" + r : r
  }
  function openFileRef(ref) {
    var r = String(ref || "")
    var line = r.match(/:(\d+)$/)
    openInNvim(line ? r.substring(0, r.length - line[0].length) : r)
  }
  function proseParts(text) {
    var source = String(text || ""), out = [], start = 0, pos = 0, summary = false, chunk = ""
    var lines = source.match(/[^\n]*(?:\n|$)/g) || []
    function flush() {
      var lead = chunk.match(/^\s*/)[0].length, trimmed = chunk.trim()
      if (trimmed.length) out.push({ text: trimmed, offset: start + lead, summary: summary })
      chunk = ""
    }
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].length) continue
      // A line that is nothing but a path becomes the file row IN PLACE, so the
      // reference is written once instead of inline plus a row underneath.
      var solo = lines[i].replace(/\n$/, "").trim()
        .match(/^`?((?:[\w.@~-]+\/)+[\w.@-]+\.\w{1,6})(:\d+)?`?[.,;:]?$/)
      if (solo) {
        flush()
        out.push({ fileRef: solo[1], shown: shownFileRef(solo[1]) + (solo[2] || ""), offset: pos })
        pos += lines[i].length
        start = pos
        continue
      }
      var isSummary = isSummaryLine(lines[i].replace(/\n$/, ""))
      if (chunk.length && isSummary !== summary) {
        flush()
        start = pos
      }
      if (!chunk.length) { start = pos; summary = isSummary }
      chunk += lines[i]
      pos += lines[i].length
    }
    if (chunk.length) {
      var lastLead = chunk.match(/^\s*/)[0].length, last = chunk.trim()
      if (last.length) out.push({ text: last, offset: start + lastLead, summary: summary })
    }
    return out
  }
  function markdownBlocks(text, entryIndex, baseOffset) {
    var source = String(text || ""), re = /```([a-zA-Z0-9_-]*)[ \t]*\n([\s\S]*?)```/g
    var out = [], m, pos = 0, base = baseOffset || 0
    while ((m = re.exec(source)) !== null) {
      if (m.index > pos) {
        var prose = source.slice(pos, m.index)
        out.push({ kind: "markdown", text: prose, start: base + pos,
                   units: _scanUnits(prose, entryIndex, "yank", base + pos) })
      }
      out.push({ kind: "fence", lang: m[1], code: m[2], start: base + m.index,
                 key: "e" + entryIndex + ":p" + (base + m.index), runnable: _shellLanguage(m[1]) })
      pos = re.lastIndex
    }
    if (pos < source.length) {
      var tail = source.slice(pos)
      out.push({ kind: "markdown", text: tail, start: base + pos,
                 units: _scanUnits(tail, entryIndex, "yank", base + pos) })
    }
    return out
  }
  function blockHints(block, rowIdx) {
    var out = [], units = block.units || []
    for (var i = 0; i < units.length; i++) {
      var target = hintForKey(units[i].key, rowIdx)
      if (target) out.push(target)
    }
    return out
  }
  function decorateMarkdown(block, rowIdx) {
    var source = String(block.text || ""), hints = blockHints(block, rowIdx)
    for (var i = hints.length - 1; i >= 0; i--) {
      var at = hints[i].start - block.start
      var marker = "\u200B[" + hints[i].label + "]\u200B"
      source = source.slice(0, at) + "<font color=\"" + _hex(Theme.surface2) + "\">" + marker
        + "</font>\u00a0" + source.slice(at)
    }
    return source
  }
  function hasImageAttachments(text) {
    return /@?[\w~./-]*heidr-pastes\/[^\s"']+/.test(String(text || ""))
  }
  function inlineAttachmentLines(text) {
    var number = 0
    return String(text || "").split("\n").map(function (line) {
      var tokens = [], re = /@?[\w~./-]*heidr-pastes\/[^\s"']+[ \t]*|[^\s]+[ \t]*/g, match
      while ((match = re.exec(line)) !== null) {
        var raw = match[0], attachment = hasImageAttachments(raw)
        if (attachment) number++
        tokens.push({ kind: attachment ? "attachment" : "text",
                      text: raw, number: number, trailing: /[ \t]$/.test(raw) })
      }
      return tokens
    })
  }
  function badgeAttachments(t) {
    var n = 0
    return String(t || "").replace(/@?[\w~./-]*heidr-pastes\/[^\s"']+/g, function () {
      n++
      return "**Image " + n + "**"
    })
  }
  function _hex(c) {
    function h(v) { var s = Math.round(v * 255).toString(16); return s.length < 2 ? "0" + s : s }
    return "#" + h(c.r) + h(c.g) + h(c.b)
  }
  // On open, land nvim in the active session's worktree + its plan (if any),
  // replacing the default splash. Runs once (first session known).
  property bool _landed: false
  // Land a few times (500/1000/1500ms) so it catches whenever nvim's socket is
  // up — idempotent, and the intro is suppressed so nothing flashes meanwhile.
  Timer {
    id: landTimer; interval: 500; repeat: true
    property int n: 0
    onTriggered: { rail.landNvim(rail.selectedRaw); n++; if (n >= 3) { running = false; n = 0; rail._landed = true } }
  }
  // Remote lovbox sessions report a BOX path (/home/lovable/…). The local nvim
  // edits those files via the SSHFS mount, so rewrite box paths to the Cockpit mirror.
  // Remote path → its local mutagen mirror. One entry per remote we sync: the old
  // lovbox rooted at /home/lovable, and the dev VM whose worktrees live under
  // ~<vmuser>/src (vm-wt mirrors those to ~/lovbox/vm). Without the VM entry,
  // live-follow cd'd nvim to a VM-absolute path that does not exist locally, which
  // is why the editor came up on an empty buffer.
  readonly property var _mirrors: [
    { remote: "/home/lovable",
      local: Quickshell.env("HOME") + "/lovbox/cockpit" },
    // The VM's worktrees mirror into REAL local git worktrees (…/work/lovable.daphen-<t>),
    // not a bare directory: gitsigns, hunk jumping and the dashboard all need a
    // repository, and a plain mirror has none — mutagen has to skip .git because a
    // worktree's .git is a FILE holding a VM-absolute gitdir.
    { remote: "/home/" + (cockpitEnv("VM_USER") || "david_karlsson_lovable_dev") + "/src/lovable-",
      local: Quickshell.env("HOME") + "/work/lovable.daphen-" }
  ]
  function _localPath(p) {
    var s = String(p || "")
    for (var i = 0; i < _mirrors.length; i++) {
      var m = _mirrors[i]
      if (s === m.remote) return m.local
      // Plain prefix, NOT only at a "/" boundary: the VM entry ends in "lovable-" so a
      // path like …/src/lovable-every-2741 has no slash after the prefix. Requiring one
      // silently matched nothing, so every remote cwd passed through as a VM path,
      // isdirectory() failed, and nvim never changed directory.
      if (s.indexOf(m.remote) === 0) return m.local + s.substring(m.remote.length)
    }
    return s
  }
  // Remote = the cwd is not under THIS machine's home. agentd reports cwd as the
  // machine running pi sees it, so a path outside our own $HOME can only be another
  // box. Hardcoding /home/lovable only matched the old lovbox and read the dev VM
  // (/home/david_karlsson_lovable_dev/...) as local.
  function _isRemote(cwd) {
    var s = String(cwd || "")
    if (!s) return false
    var home = String(Quickshell.env("HOME") || "/home/daphen")
    return !(s === home || s.indexOf(home + "/") === 0)
  }
  // Inverse of _localPath: a path under the local mirror → the path the BOX sees.
  // Needed because pi runs IN the box, so an @attachment must be a box path.
  function _remotePath(p) {
    var s = String(p || "")
    for (var i = 0; i < _mirrors.length; i++) {
      var m = _mirrors[i]
      if (s === m.local) return m.remote
      if (s.indexOf(m.local) === 0) return m.remote + s.substring(m.local.length)
    }
    return s
  }
  // ── image paste ─────────────────────────────────────────────────────────────
  // pi takes images as `@path` references in the prompt, so a pasted image becomes
  // a file plus an @mention. The file is written into the SELECTED SESSION's cwd
  // (via the mirror for remote work) so mutagen carries it to the box and pi can
  // actually open it — a local /tmp path would not exist over there.
  property var pastedImages: []   // filenames pasted this session, shown as composer chips
  // pi needs @references in the prompt: each [image N] token is replaced IN PLACE
  // by its file ref at send time. A token the user deleted sends nothing — deletion
  // is the drop gesture.
  function attachRefs(t) {
    return String(t || "").replace(/\[(img\d+)\]/g, function (all, stem) {
      var f = ""
      for (var i = 0; i < pastedImages.length; i++)
        if (String(pastedImages[i]).indexOf(stem + ".") === 0) { f = pastedImages[i]; break }
      if (!f) return all
      // Remote: worktree-relative (the box's absolute path differs from ours).
      // Local: the cache dir's absolute path — the project stays untouched.
      return pasteRemote ? "@.heidr-pastes/" + f
                         : "@" + Quickshell.env("HOME") + "/.cache/heidr-pastes/" + f
    })
  }
  // Local vs remote pastes are DIFFERENT problems. A remote (VM) session needs the
  // file inside the worktree so mutagen/scp can carry it to the box, and the @ref
  // must be worktree-relative (the box path differs). A LOCAL pi reads any absolute
  // path — its pastes live in ~/.cache/heidr-pastes and never touch the project.
  readonly property bool pasteRemote: {
    var cwd = _sessionCwdOf(selectedRaw)
    return _isRemote(cwd)
  }
  property string pasteDirFor: {
    var cwd = _sessionCwdOf(selectedRaw)
    if (!_isRemote(cwd)) return Quickshell.env("HOME") + "/.cache/heidr-pastes"
    return rail._localPath(cwd) + "/.heidr-pastes"
  }
  Process {
    id: pasteProc
    stdout: StdioCollector {
      onStreamFinished: {
        var out = String(this.text || "").trim()
        if (!out || out === "NOIMAGE") { composerInput.paste(); return }   // no image → normal text paste
        // A short [image N] token lands AT THE CARET — the reference then replaces it
        // in place at send time (attachRefs), so the image sits where you pasted it,
        // for you and for the agent. Deleting the token drops the image from the send.
        rail.pastedImages = rail.pastedImages.concat([out])
        // The token IS the file's name (img7 for img7.png): what you see, what the
        // agent reads, and what the badge shows are the same word.
        composerInput.insert(composerInput.cursorPosition, "[" + out.replace(/\.[a-z]+$/, "") + "] ")
        rail._pushPasteRemote(out)
      }
    }
  }
  // A paste for a REMOTE session rides two channels: the @reference goes with the prompt
  // (milliseconds) while the file itself waits for mutagen's watch→scan→ship cycle
  // (~1-3s) — so paste-and-Enter-immediately could reach pi before its file existed.
  // Push the file up eagerly over the same ControlMaster socket vm-sync keeps warm
  // (~150ms; a cold dial still beats typing the message). mutagen syncing it again a
  // moment later is a harmless no-op — identical content resolves clean.
  function _pushPasteRemote(name) {
    var cwd = _sessionCwdOf(selectedRaw)
    if (!_isRemote(cwd)) return
    var vmuser = cockpitEnv("VM_USER") || "david_karlsson_lovable_dev"
    // Only the dev VM speaks plain ssh/scp; a lovbox mirror keeps mutagen as its carrier.
    if (cwd.indexOf("/home/" + vmuser + "/") !== 0) return
    var host = cockpitEnv("VM_HOST")
             || ((cockpitEnv("VM") || "dev-heidr-2a39") + ".workstation.lovable.net")
    var ssh = "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
            + " -o ControlMaster=auto -o ControlPath=" + Quickshell.env("XDG_RUNTIME_DIR") + "/heidr-vm-cm"
            + " -o ControlPersist=600 -o ConnectTimeout=15"
    var rdir = cwd + "/.heidr-pastes"
    var local = pasteDirFor + "/" + name
    Quickshell.execDetached(["sh", "-c",
      ssh + " " + vmuser + "@" + host + " 'mkdir -p " + JSON.stringify(rdir) + "' && "
      + "scp " + ssh.substring(4) + " " + JSON.stringify(local) + " "
      + vmuser + "@" + host + ":" + JSON.stringify(rdir) + "/"])
  }
  function pasteImage() {
    // One shell pass: detect an image flavour, write it, print the path (or NOIMAGE).
    pasteProc.running = false
    pasteProc.command = ["sh", "-c",
      // Teach the host repo to ignore the paste stash the moment it exists: without
      // this, agents running `git add -A` commit screenshots, and the changes view
      // counts them as project files.
      'd=' + JSON.stringify(rail.pasteDirFor) + '; mkdir -p "$d" || exit 0; ' +
      'g=$(cd "$d/.." && git rev-parse --absolute-git-dir 2>/dev/null); ' +
      'if [ -n "$g" ]; then grep -qxF ".heidr-pastes/" "$g/info/exclude" 2>/dev/null || { mkdir -p "$g/info"; echo ".heidr-pastes/" >> "$g/info/exclude"; }; fi; ' +
      't=$(wl-paste --list-types 2>/dev/null | grep -m1 "^image/"); ' +
      '[ -n "$t" ] || { echo NOIMAGE; exit 0; }; ' +
      'e=${t#image/}; [ "$e" = jpeg ] && e=jpg; [ "$e" = svg+xml ] && e=svg; ' +
      // Sequential img1/img2/… per session: the reference has to be readable in the
      // sentence ("before: @img1.png, after: @img2.png"), and a timestamped name made
      // two pastes indistinguishable at a glance.
      'n=$(ls "$d" 2>/dev/null | grep -c "^img[0-9]"); n=$((n+1)); ' +
      'f="$d/img$n.$e"; ' +
      'wl-paste --type "$t" > "$f" 2>/dev/null && echo "img$n.$e" || echo NOIMAGE']
    pasteProc.running = true
  }

  // A landing is only as fresh as the session's cwd: a re-homed/respawned session
  // (stop + spawn at a new dir) otherwise kept the OLD landing forever — nvim sat
  // on the previous dir's dashboard (or the lovable fallback) looking broken.
  property string _landedFor: ""
  property bool _planRebindPending: false
  property string _planRebindSid: ""
  property string _planRebindSlug: ""
  Connections {
    target: rail.agentd
    function onSessionsChanged() {
      if (!rail.selectedRaw) return
      for (var i = 0; i < rail.agentd.sessions.length; i++) {
        var ss = rail.agentd.sessions[i]
        if (ss.id === rail.selectedRaw) {
          var key = ss.id + "@" + ss.cwd + "#" + (ss.plan || "")
          if (rail._planRebindPending && ss.id === rail._planRebindSid
              && String(ss.plan || "") === rail._planRebindSlug) {
            rail._landedFor = key
            var slug = rail._planRebindSlug
            rail._planRebindPending = false
            rail._planRebindSid = ""; rail._planRebindSlug = ""
            if (slug.length) rail.openPlanInNvim(slug)
            return
          }
          if (rail._landed && rail._landedFor && rail._landedFor.indexOf(ss.id + "@") === 0
              && rail._landedFor !== key) rail.landNvim(ss.id)
          return
        }
      }
    }
  }
  function openPlanInNvim(slug) {
    if (!slug || !nvimSock.length) return
    Quickshell.execDetached(["nvim", "--server", nvimSock, "--remote-expr",
                             'v:lua.require("plan-nvim").open(' + JSON.stringify(slug) + ')'])
  }
  function landNvim(sid) {
    if (!sid || !agentd) return
    var ss = _sessionOf(sid)
    var cwd = ss ? String(ss.cwd || "") : "", plan = ss ? String(ss.plan || "") : ""
    if (!cwd) return
    _landedFor = sid + "@" + cwd + "#" + plan
    var repo = rail.remoteOffered ? Quickshell.env("HOME") + "/work/lovable" : cwd
    var dashAt = function (d) {
      return 'v:lua.require("cockpit").dashboard(' + JSON.stringify(d) + ',' + JSON.stringify(sid) + ')'
    }
    var fallback = plan.length
      ? 'v:lua.require("plan-nvim").open(' + JSON.stringify(plan) + ')'
      : dashAt(repo)
    // A session with edit history resumes at its latest changed file regardless of
    // whether the turn is still streaming or has just settled idle. A remote session
    // without a local mirror/file lands on its bound plan instead of silently no-oping.
    if (agentd.lastEditFor(sid) && nvimSock.length) {
      var lcwd0 = rail._localPath(cwd)
      var lp0 = rail._localPath(String(agentd.lastEditFor(sid)))
      if (lp0.charAt(0) !== "/") lp0 = lcwd0 + "/" + lp0
      var follow = 'v:lua.require("cockpit").follow_remote("' + lcwd0 + '","' + lp0 + '", v:true)'
      var land = 'isdirectory("' + lcwd0 + '") && filereadable("' + lp0 + '")'
        + ' ? (execute("cd ' + lcwd0 + '") . ' + dashAt(lcwd0) + ' . ' + follow + ') : ' + fallback
      Quickshell.execDetached(["nvim", "--server", nvimSock, "--remote-expr", land])
      _alignMirror(sid)
      return
    }
    cwd = rail._localPath(cwd)   // box path → local mutagen mirror (no-op for local sessions)
    // Plan location depends on where the session lives: local work uses the vault,
    // a lovbox session has no vault so plan-ticket writes <worktree>/.plans/.
    // Build a vimscript chain that prefers the worktree plan, then the vault, then
    // the session dashboard — filereadable() runs inside nvim, which is the only
    // side that can actually test the paths.
    // The dashboard needs a git worktree. A remote session's mirror deliberately has no
    // .git (a worktree's .git is a FILE holding a VM-absolute gitdir), so pointing the
    // dashboard at the mirror renders an almost-empty buffer — the "giant whitespace".
    // Fall back to the local checkout for the dashboard while still cd'ing to the mirror.
    // The no-.git fallback repo is SCOPE-BOUND: the lovable checkout is only a
    // sane dashboard home on the work instance — the private Cockpit was falling
    // back to it and showing the lovable fleet dash for ~/personal sessions.
    var dash = '((isdirectory("' + cwd + '/.git") || filereadable("' + cwd + '/.git")) ? '
             + dashAt(cwd) + ' : ' + fallback + ')'
    // Always the DASHBOARD, never the plan. The dashboard is the session's home — it's
    // where the app, the tickets and the plan are all reachable from — so opening the plan
    // buffer instead dropped you somewhere you then had to navigate out of. Read the plan
    // from the dashboard when you want it.
    var open = dash
    // Guard the cd: a session whose worktree isn't mirrored locally (the VM's main
    // checkout, an unsynced tree) maps to a path that does not exist here, and cd'ing
    // there left nvim on an empty buffer staring at nothing.
    var expr = 'isdirectory("' + cwd + '") ? (execute("cd ' + cwd + '") . ' + open + ') : ' + fallback
    if (!nvimSock.length) return
    Quickshell.execDetached(["nvim", "--server", nvimSock, "--remote-expr", expr])
    _alignMirror(sid)
  }

  // A remote session's local mirror carries files but not git history, so the moment the
  // agent commits or rebases on the box, the mirror's HEAD is stale and git blames every
  // upstream commit that came down on YOUR diff (one rebase read as 5376 files in lualine).
  // `vm-sync --align` moves HEAD + index only — no checkout, no clean, no file touched —
  // so it is safe to fire on every switch. It exits immediately when already aligned.
  function _alignMirror(sid) {
    var cwd = _sessionCwdOf(sid)
    if (!cwd || !rail._isRemote(cwd)) return
    var m = String(sid).match(/([a-z]+-\d+)/i)
    if (!m) return
    Quickshell.execDetached([Quickshell.env("HOME") + "/.config/niri/scripts/vm-sync",
                             "--align", m[1]])
  }

  function openInNvim(path) {
    if (!path || !String(path).length || !nvimSock.length) return
    var p = String(path)
    if (p.indexOf("~/") === 0) p = Quickshell.env("HOME") + p.substring(1)
    if (p.charAt(0) !== "/") {
      var repoPath = rail._localPath(changesCwd ? changesCwd + "/" + p : p)
      if (/^(inbox|journal|meetings|memory|plans|references|reviews)\//.test(p)) {
        var vaultPath = Quickshell.env("HOME") + "/personal/notes/storage/" + p
        var chosen = "filereadable(" + JSON.stringify(vaultPath) + ") ? "
                   + JSON.stringify(vaultPath) + " : " + JSON.stringify(repoPath)
        Quickshell.execDetached(["nvim", "--server", nvimSock, "--remote-expr",
                                 'execute("edit " . fnameescape(' + chosen + "))"])
        rail.focusNvim()
        return
      }
      p = repoPath
    }
    p = rail._localPath(p)
    var quoted = JSON.stringify(p)
    var expr = 'filereadable(' + quoted + ') ? execute("edit " . fnameescape(' + quoted + '))'
             + ' : execute("echohl WarningMsg | echomsg " . string("file no longer exists: " . ' + quoted + ') . " | echohl None")'
    Quickshell.execDetached(["nvim", "--server", nvimSock, "--remote-expr", expr])
    rail.focusNvim()
  }
  // Prose blocks of an agent turn (the headline answer).
  function turnProse(items) { return (items || []).filter(x => x.kind === "text") }
  // Housekeeping rows (compaction). These have no prose/activity delegate of their own,
  // so a compaction card rendered EMPTY while the identical text appeared as a live
  // transient at the tail — the marker looked misplaced and duplicated.
  function turnSys(items) { return (items || []).filter(x => x.kind === "sys") }
  // The pi turn-recap line ("✧ … ; next question/action: …") — coloured sky so
  // the recap reads apart from the body (matches the nvim rail's summary hue).
  function isSummaryLine(l) {
    var s = String(l || "")
    return /^\s*[✦✧⟢⟣✤◆❉]/.test(s) || /\bnext\s+(question|action)\s*:/i.test(s)
  }
  // Thinking blocks — shown inline (the visible thought-process trail).
  function turnThinks(items) { return (items || []).filter(x => x.kind === "think") }
  function turnUserBash(items) { return (items || []).filter(x => x.kind === "userbash") }
  function isPlanMetadataEdit(item) {
    if (!item || item.kind !== "edit") return false
    var path = String(item.path || item.file || "")
    return /\.(progress|review)\.json$/.test(path)
      || /(^|\/)\.plans\/[^/]+\.md$/.test(path)
      || /\/notes\/storage\/plans\/[^/]+\.md$/.test(path)
  }
  // Compact one-line summary of a turn's TOOL activity (thinking is shown, not
  // counted): "4 bash · 6 read · edited file.ts".
  function turnActivitySummary(items) {
    var counts = {}, editFiles = [], interrupts = 0, errors = 0
    for (var i = 0; i < (items || []).length; i++) {
      var it = items[i]
      if (it.kind === "text" || it.kind === "think" || it.kind === "userbash" || isPlanMetadataEdit(it)) continue
      else if (it.kind === "edit") {
        var file = String(it.file || it.path || "")
        if (file && editFiles.indexOf(file) < 0) editFiles.push(file)
      }
      else if (it.kind === "cmd" && it.tool === "error") {
        // "1 error" says nothing. Name the interrupt; other errors count as words.
        if (String(it.text || "").indexOf("⏹") === 0) interrupts++
        else if (String(it.text || "").indexOf("⚡") === 0) { counts["aborted externally"] = 1 }
        else errors++
      }
      else if (it.kind === "cmd" && it.tool === "info") continue   // markers, not activity
      else if (it.kind === "cmd" && it.failed === true) { counts[it.tool] = (counts[it.tool] || 0) + 1; errors++ }
      else if (it.kind === "group") counts[it.tool] = (counts[it.tool] || 0) + (it.cmds ? it.cmds.length : 1)
      else if (it.kind === "cmd") counts[it.tool] = (counts[it.tool] || 0) + 1
    }
    var parts = []
    for (var k in counts) parts.push(counts[k] + " " + k)
    if (editFiles.length === 1) parts.push("edited " + editFiles[0])
    else if (editFiles.length) parts.push("edited " + editFiles.length + " files")
    if (interrupts) parts.push("interrupted")
    if (errors) parts.push(errors === 1 ? "1 error" : errors + " errors")
    return parts.join("  ·  ")
  }
  function turnActivityItems(items) {
    return (items || []).filter(x => x.kind !== "text" && x.kind !== "think" && x.kind !== "userbash"
      && !isPlanMetadataEdit(x) && !(x.kind === "cmd" && x.tool === "info"))
  }
  function turnEditItems(items) { return turnActivityItems(items).filter(x => x.kind === "edit") }
  function turnBashItems(items) {
    var activity = turnActivityItems(items), out = []
    for (var i = 0; i < activity.length; i++) {
      var entry = activity[i]
      if (entry.tool !== "bash") continue
      if (entry.kind === "group") {
        var cmds = entry.cmds || []
        for (var j = 0; j < cmds.length; j++)
          out.push({ kind: "cmd", tool: "bash", text: cmds[j].text, command: cmds[j].command || "" })
      } else out.push(entry)
    }
    return out
  }
  function turnInfos(items) {
    return (items || []).filter(x => x.kind === "cmd" && x.tool === "info").map(x => String(x.text || ""))
  }

  function feedCopyTarget(item) {
    if (!item) return ""
    if (item.kind === "turn")   // a grouped agent turn → join its prose blocks
      return (item.items || []).filter(x => x.kind === "text").map(x => x.text).join("\n\n")
    return item.command && item.command.length ? item.command : (item.text || item.file || "")
  }

  // Manage focus imperatively — a `focus:` binding fights forceActiveFocus and
  // wedges the rail after the first composer round-trip.
  // Coming back from nvim should land where you left (Cockpit behavior): the
  // cursor position survives on its own (it's just `cur`), but insert mode was
  // being force-cleared on every return, so leaving from the composer dumped you
  // back in the roster. Remember it across the blur instead.
  property bool _wasInsert: false
  // The feed row the cursor held when focus LEFT the rail — restored on return
  // so hopping to nvim and back doesn't lose your reading position. Explicit
  // landing gestures (Super+T roster jump, a click) clear it and win.
  property string _blurFeedKey: ""
  onFocusedChanged: {
    if (!focused) {
      _wasInsert = insert; insert = false
      _blurFeedKey = (cur >= rSize && groupedFeed[cur - rSize])
        ? String(groupedFeed[cur - rSize].key || "") : ""
      return
    }
    if (_wasInsert) { enterInsert(); return }   // was typing → back into the composer
    insert = false
    if (_blurFeedKey.length) {
      var bi = _feedIndexOf(_blurFeedKey)
      _blurFeedKey = ""
      if (bi >= 0) {
        cur = rSize + bi
        feedScroll.cursorMoved(bi, bi === groupedFeed.length - 1)
        forceActiveFocus()
        return
      }
    }
    // A collapsed roster shows only a glance (no per-row cursor). If the
    // cursor was parked in the roster range, entering the rail would leave
    // nothing highlighted — land it on the latest chat message instead.
    if (!rosterExpanded && cur < rSize && navTotal > rSize) cur = navTotal - 1
    forceActiveFocus()
  }

  // Font scale anchored to the design system's base (Theme.fontSize = 14).
  readonly property int fsHeader: Theme.fontSize + 3
  readonly property int fsName:   Theme.fontSize + 2
  readonly property int fsBody:   Theme.fontSize + 1
  readonly property int fsMeta:   Theme.fontSize

  // Turn-recap summary hue — electric, brightened + desaturated, with the hue
  // nudged off electric's blue-violet toward sky's blue so it doesn't read pink.
  //   summaryHueMix 0 = electric hue (violet), 1 = sky hue (blue)
  //   summarySat    <1 desaturates (calmer)
  //   summaryLight  >1 brightens toward white
  readonly property real summaryHueMix: 0.6
  readonly property real summarySat: 0.5
  readonly property real summaryLight: 1.3
  readonly property color summaryColor: Qt.hsla(
    Theme.electric.hslHue * (1 - summaryHueMix) + Theme.sky.hslHue * summaryHueMix,
    Math.max(0, Math.min(1, Theme.electric.hslSaturation * summarySat)),
    Math.max(0, Math.min(1, Theme.electric.hslLightness * summaryLight)),
    1.0)

  // COCKPIT_DEMO=1 (or legacy HEIDR_DEMO) forces the mock showcase so every
  // session and feed state is visible without a live daemon.
  readonly property bool demo: cockpitEnv("DEMO") === "1"

  // --- Roster: real agentd sessions when available, else mock ---
  readonly property var liveSessions:
    (agentd && agentd.sessions && agentd.sessions.length) ? agentd.sessions : []
  // Liveness is about having a DAEMON, not about having sessions. Keying it on
  // liveSessions.length meant "connected but no sessions yet" and "tunnel is dead"
  // both rendered the mock showcase — fake sessions that look completely real
  // (this misread bit twice: once as a phantom roster, once when the lovbox tunnel
  // dropped). Now mock appears only in explicit demo mode; a connected-but-empty
  // daemon shows an empty roster, and a dead socket shows the disconnected note.
  readonly property bool live: !demo
  readonly property bool daemonUp: !!(agentd && agentd.connected)

  // Strip worktree prefixes only — never trim after the ticket id: sibling
  // sessions like every-2741-runtime must stay distinguishable from every-2741.
  function shortName(n) {
    return String(n).replace(/^lovable\.daphen-/, "").replace(/^daphen-/, "")
  }
  function stateLabel(st) {
    if (st === "streaming") return "working"
    if (st === "asleep")    return "asleep"
    if (st === "error")     return "error"
    if (st === "offline")   return "offline"   // its daemon/tunnel is gone
    return "idle"
  }
  // The working orb's hue names the ACTION: reading is calm blue, editing is
  // green (something is changing), running commands is orange (side effects),
  // mcp/asks and thinking (no tool) idle on the default azure -- electric's
  // blue-violet read purple in the aurora orb and was voted out.
  // 1s heartbeat for elapsed-time displays (running tool call duration).
  property int nowTick: 0
  Timer { interval: 1000; repeat: true; running: true; onTriggered: rail.nowTick++ }
  // "<tool> · 1m32" for the RUNNING tool call, ticking; "" when idle.
  function runningToolLabel(sid) {
    nowTick
    agentd ? agentd.curToolGen : 0
    // Compaction is invisible otherwise: no tool runs, the orb just spins.
    var cAt = agentd ? agentd.compactingSince(sid) : 0
    if (cAt) {
      var cs = Math.max(0, Math.round((Date.now() - cAt) / 1000))
      return "compacting context · " + cs + "s"
    }
    if (!agentd || !agentd.curToolLiveFor(sid)) return ""
    var secs = Math.max(0, Math.round((Date.now() - agentd.curToolAtFor(sid)) / 1000))
    var el = secs >= 60 ? Math.floor(secs / 60) + "m" + String(secs % 60).padStart(2, "0") : secs + "s"
    return (agentd.curToolFor(sid) || "tool") + " · " + el
  }
  function actionGlow(sid) {
    agentd ? agentd.curToolGen : 0
    return AgentActivity.colorFor(agentd ? agentd.curToolFor(sid) : "")
  }
  // Composer chrome color is FIXED per theme, not action-reactive — the input
  // frame recoloring with every tool change was too much motion. Light rides
  // ink (not electric); dark keeps the pale azure "thinking" tint.
  readonly property color activeRing: Theme.mode === "light"
    ? Theme.ink
    : Qt.hsla(0.583, 0.29, 0.90, 1)
  // One colour vocabulary for BOTH roster states: the collapsed dots and the expanded
  // rows now read identically, so "what is this session doing" is the same glance either
  // way. Working is the orb, never a dot.
  function dotColor(st) {
    if (st === "streaming") return Theme.green
    if (st === "error")     return Theme.red
    // Idle and asleep are both resting states. Neither needs an attention colour;
    // selecting an asleep session wakes it automatically.
    return Theme.fg_muted
  }
  function toolIcon(tool) {
    if (tool === "info") return "circle-info"
    if (tool === "mcp") return "puzzle-piece"
    if (tool === "grep" || tool === "ripgrep" || tool === "search_files"
        || tool === "glob" || tool === "find") return "magnifier"
    if (tool === "bash" || tool === "shell") return "chevron-right"
    return "gear-2"
  }

  readonly property var mockFeatured: ({ name: "every-2662", rawName: "every-2662", state: "working 13s", status: "streaming" })
  readonly property var mockRoster: [
    { name: "every-2662", rawName: "every-2662", idle: "working 13s", status: "streaming", linked: false, depth: 0 },
    { name: "lovable",    rawName: "lovable",    idle: "idle 8m",     status: "idle",      linked: false, depth: 0 },
    { name: "every-2640", rawName: "every-2640", idle: "working",     status: "streaming", linked: true,  depth: 1 },
    { name: "every-2457", rawName: "every-2457", idle: "asleep",      status: "asleep",    linked: true,  depth: 1 },
    { name: "every-2515", rawName: "every-2515", idle: "idle 2h",     status: "idle",      linked: false, depth: 0 }
  ]
  readonly property var mockChanges: [
    { path: "web/modules/design-system/home/hooks/useComponentTiles.ts", add: 123, del: 76 },
    { path: "web/modules/design-system/home/hooks/useComponentTiles.test.ts", add: 179, del: 159 },
    { path: "web/modules/design-system/home/DesignSystemCanvasView.tsx", add: 42, del: 8 }
  ]

  // Default landing = the streaming session (or the first) — but only until the
  // user selects one. The FEATURED card is whatever is SELECTED, so the outlined
  // "active" card, the chat, and the composer all point at the same session.
  // Stable default: the first top-level session by name (the orchestrator/root),
  // NOT whichever session happens to be streaming — otherwise the selection (and
  // the chat) jumps around as subagents start/stop working.
  // Assigned imperatively, not bound: with one socket per scope the roster arrives in
  // pieces, and a live binding re-picked the landing session (re-cd'ing nvim) as each
  // daemon reported. Wait for agentd.settled, choose once, then keep that choice for
  // as long as the session exists. (A binding that read its own last value here is a
  // loop — hence the explicit recompute.)
  property string defaultRaw: ""
  property string savedRaw: ""
  readonly property string selectionStatePath: Quickshell.env("HOME") + "/.local/state/cockpit/selected-" + instanceName + "-" + scopeMode
  FileView {
    id: selectionFile
    path: rail.selectionStatePath
    onLoaded: { rail.savedRaw = String(text() || "").trim(); rail._recomputeDefault() }
  }
  Process { id: selectionWrite }
  function rememberSelection(name) {
    if (!name) return
    selectionWrite.running = false
    selectionWrite.command = ["sh", "-c", 'mkdir -p "$1"; printf %s "$2" > "$3"',
                              "sh", Quickshell.env("HOME") + "/.local/state/cockpit", name, selectionStatePath]
    selectionWrite.running = true
  }
  function _recomputeDefault() {
    if (!live || !agentd || !agentd.settled) { defaultRaw = ""; return }
    if (defaultRaw && liveSessions.some(s => s.name === defaultRaw)) return
    if (savedRaw && liveSessions.some(s => s.name === savedRaw)) { defaultRaw = savedRaw; return }
    var roots = liveSessions.filter(s => !s.parent)
    var pool = (roots.length ? roots : liveSessions).slice()
    pool.sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
    defaultRaw = pool.length ? pool[0].name : ""
  }
  onLiveSessionsChanged: _recomputeDefault()
  onScopeModeChanged: {
    activeRaw = ""
    defaultRaw = ""
    recentSelections = []
    savedRaw = ""
    rosterOverride = false
    Qt.callLater(function() { selectionFile.reload(); rail._recomputeDefault() })
  }
  Connections {
    target: rail.agentd
    function onSettledChanged() { rail._recomputeDefault() }
  }
  readonly property string selectedRaw: activeRaw || defaultRaw
  readonly property string selectedGoal: {
    for (var gi = 0; gi < liveSessions.length; gi++)
      if (liveSessions[gi].name === selectedRaw) return String(liveSessions[gi].goal || "")
    return ""
  }
  readonly property string selectedCwd: {
    for (var ci = 0; ci < liveSessions.length; ci++)
      if (liveSessions[ci].name === selectedRaw) return String(liveSessions[ci].cwd || "")
    return ""
  }
  readonly property string selectedParent: {
    for (var pi = 0; pi < liveSessions.length; pi++)
      if (liveSessions[pi].name === selectedRaw) return String(liveSessions[pi].parent || "")
    return ""
  }

  readonly property string selectedStatus: {
    for (var si = 0; si < liveSessions.length; si++)
      if (liveSessions[si].name === selectedRaw) return String(liveSessions[si].status || "")
    return ""
  }

  readonly property bool selectedIsOrchestrator: {
    for (var oi = 0; oi < liveSessions.length; oi++)
      if (liveSessions[oi].name === selectedRaw)
        return String(liveSessions[oi].profile || "").indexOf("orchestrator") >= 0
    return false
  }
  // Where the ORCHESTRATOR ROLE lives right now: "lovable" = this laptop, "work" = the
  // dev VM. The armed one wins (handover pins the goal on exactly one side); otherwise
  // the live one. Empty when neither is up, which the toggle renders as unknown.
  // Which host holds the orchestrator role. RECORDED by cockpit-handover, never guessed:
  // deriving it from "whoever has a goal armed" moved the role on its own the moment a
  // goal cleared, so the rail showed the local session as orchestrator with the VM's
  // workers under it (David, 2026-08-26). The role now changes only when he toggles.
  property string recordedOrchScope: ""
  FileView {
    path: Quickshell.env("HOME") + "/.local/state/cockpit/orchestrator-holder"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      var v = String(text() || "").trim()
      rail.recordedOrchScope = (v === "lovable" || v === "work") ? v : ""
    }
  }
  readonly property string orchScope: {
    // Honour the record whenever that side actually has an orchestrator session.
    if (recordedOrchScope.length) {
      for (var j = 0; j < liveSessions.length; j++) {
        var r = liveSessions[j]
        if (String(r.profile || "").indexOf("orchestrator") >= 0
            && String(r.scope || "") === recordedOrchScope) return recordedOrchScope
      }
    }
    // No record yet (first run): fall back to inference so the rail still resolves.
    var armed = "", live = ""
    for (var i = 0; i < liveSessions.length; i++) {
      var x = liveSessions[i]
      if (String(x.profile || "").indexOf("orchestrator") < 0) continue
      var sc = String(x.scope || "")
      if (sc !== "lovable" && sc !== "work") continue
      if (String(x.goal || "").length) armed = sc
      else if (!live) live = sc
    }
    return armed || live
  }

  readonly property string selectedPlan: {
    for (var i = 0; i < liveSessions.length; i++)
      if (liveSessions[i].name === selectedRaw) return String(liveSessions[i].plan || "")
    return ""
  }

  // Pending ask_user question (extension_ui_request) for the selected session.
  // Reactive to agentd.askGen so it clears the instant we answer.
  readonly property var pendingAsk: {
    if (!agentd || !selectedRaw) return null
    agentd.askGen   // reactive dependency
    return agentd.askFor(selectedRaw)
  }
  function answerAsk(payload) { if (agentd && pendingAsk) agentd.answerAsk(selectedRaw, payload) }
  readonly property var pendingUserBash: agentd ? agentd.userBashPayload(pendingAsk) : null
  // A question the agent stopped on, found in the transcript. It cannot be answered from
  // here (the resolver died with the process that asked), so it is a notice, not a card —
  // the way forward is a fresh prompt carrying the decision.
  readonly property var staleAsk: {
    if (!agentd || !selectedRaw) return null
    agentd.staleAskGen   // reactive dependency
    return agentd.staleAskFor(selectedRaw)
  }
  function dismissStaleAsk() { if (agentd && selectedRaw) agentd.dismissStaleAsk(selectedRaw) }
  // The whole point of an ask is that it blocks: take the keyboard the moment one lands.
  // A free-text ask enters insert so the input is already yours; a confirm/select ask
  // must EXIT insert — sending leaves the composer in insert on purpose, so an ask right
  // after a send otherwise landed with insert still true, and the key handler's insert
  // guard ate y/n while the hidden composer had no focus: keys went nowhere at all.
  onPendingAskChanged: {
    if (!pendingAsk) { askDeferred = false; return }
    if (insert && composerText.length > 0) { askDeferred = true; return }
    askDeferred = false
    var m = pendingAsk.method
    if (m === "input" || m === "editor") { rail.requestFocus(); Qt.callLater(rail.enterInsert) }
    else rail.exitInsert()
  }

  readonly property var featured: {
    if (!live) return mockFeatured
    var arr = liveSessions.filter(s => s.name === selectedRaw)
    var f = arr.length ? arr[0] : liveSessions[0]
    // No sessions at all (daemon up but idle, or the tunnel dropped) — everything
    // downstream reads .name, so hand back a placeholder rather than undefined.
    if (!f) return { name: daemonUp ? "no sessions" : "disconnected", rawName: "", state: "", status: "idle" }
    return { name: shortName(f.name), rawName: f.name, state: stateLabel(f.status), status: f.status }
  }
  // A turn ending is when the agent's commits land, so realign the mirror then too —
  // otherwise a commit made while you sit in the session leaves lualine stale until you
  // switch away and back. Cheap: the align exits immediately when nothing moved.
  onFeaturedStreamingChanged: if (!featuredStreaming && selectedRaw) _alignMirror(selectedRaw)

  // The ONE bool the thinking pill + orb depend on. Being a bool, its binding only
  // notifies consumers when it actually flips (stream start/stop) — decoupled from
  // `featured`, which allocates a fresh object on every roster tick.
  // Includes optimistically-pending sends (agentd's roster lags the prompt by up to
  // tens of seconds over the tunnel), so the pill appears the moment you hit enter
  // instead of leaving a live session looking dead.
  readonly property bool featuredStreaming: {
    if (agentd && agentd.pendingGen >= 0 && agentd.isBusy(selectedRaw)) return true
    if (!live) return mockFeatured.status === "streaming"
    var arr = liveSessions
    for (var i = 0; i < arr.length; i++) if (arr[i].name === selectedRaw) return arr[i].status === "streaming"
    return false
  }
  // Depth-ordered roster: children (spawned subagents) nest under their parent
  // session. `parent` is the parent's NAME; roots are top-level sessions.
  readonly property var rosterList: {
    if (!live) return mockRoster
    var all = liveSessions, children = {}, roots = [], activeKids = [], activeCwd = ""
    for (var i = 0; i < all.length; i++) {
      var s = all[i]
      // The ACTIVE session lives in the header glance, not the list — its
      // children lead the list, ↳-nested as if under the header.
      if (s.name === rail.selectedRaw) { activeCwd = s.cwd || ""; continue }
      // Only the orchestrator that HOLDS the role belongs in the roster. Handover stands
      // the other host's one down but leaves it registered, and showing both reads as two
      // conductors (David, 2026-08-25).
      if (String(s.profile || "").indexOf("orchestrator") >= 0
          && rail.orchScope.length && String(s.scope || "") !== rail.orchScope) continue
      if (s.parent === rail.selectedRaw) activeKids.push(s)
      else if (s.parent && all.some(x => x.name === s.parent))
        (children[s.parent] = children[s.parent] || []).push(s)
      else roots.push(s)
    }
    // STABLE order: name only. Recency-first meant the list reshuffled every time a
    // session emitted an event — dots jumped in the collapsed row and rows swapped places
    // under the cursor while reading (David, 2026-08-25). The only thing that changes
    // position now is you activating a session, which lifts it into the header glance.
    var byName = (a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0
    roots.sort(byName)
    activeKids.sort(byName)
    for (var key in children) children[key].sort(byName)
    var out = []
    function walk(s, depth, parentCwd) {
      out.push({ name: shortName(s.name), rawName: s.name, idle: stateLabel(s.status),
                 status: s.status, offline: !!s.offline, linked: !!s.parent, cwd: s.cwd || "",
                 hasWorktree: /\.daphen-|\/work\//.test(s.cwd || ""),
                 // A devenv slice belongs to a WORKTREE, not to the main checkout. Local
                 // worktrees are <repo>.daphen-<t>, VM ones <repo>-<t>; the plain repo
                 // root (…/work/lovable, …/src/lovable) has none, so a session opened
                 // there — an orchestrator, a one-off — must not claim one.
                 // …and never a CHILD in its parent's worktree: the babysitter/watcher
                 // shares the ticket session's cwd, but the slice belongs to the parent.
                 devenv: /\.daphen-[^/]+$|\/lovable-[^/]+$/.test(s.cwd || "") && s.cwd !== parentCwd,
                 remote: rail._isRemote(s.cwd), scope: s.scope || "",
                 profile: s.profile || "", plan: s.plan || "",
                 depth: Math.min(depth, 1) })  // one level deep only
      var kids = children[s.name] || []
      for (var j = 0; j < kids.length; j++) walk(kids[j], depth + 1, s.cwd || "")
    }
    for (var k = 0; k < activeKids.length; k++) walk(activeKids[k], 1, activeCwd)
    for (var r = 0; r < roots.length; r++) walk(roots[r], 0)
    return out
  }

  // ── new session ─────────────────────────────────────────────────────────────
  // Enter on the roster's last row opens this: pick where it runs, name it, done.
  // local  → an agentd session in the lovable scope at the main checkout
  // remote → `vm-wt <ticket>`, which also makes the worktree + devenv slice + mirror
  property bool newOpen: false
  property string newMode: ""      // "" = choosing, then "local" | "remote"
  // Remote (VM worktree) sessions are a LOVABLE concept — the personal scope has no
  // VM, so its new-session flow skips the l/r chooser and goes straight to local.
  readonly property bool remoteOffered: scopeMode === "work"
  // Folder-first new-session flow (declarative-sessions plan): n opens a
  // FOLDER list; picking one shows resume-or-new for that folder.
  property var newFolders: []       // [{path, name}] recent-first
  property string newFolder: ""     // chosen folder ("" = still picking)
  property int newCur: 0            // cursor within the current pane
  property string newFilter: ""     // fuzzy filter while picking a folder
  Process {
    id: folderScan
    running: false
    stdout: SplitParser { onRead: data => {
      var pth = String(data).trim()
      if (!pth.length) return
      var arr = rail.newFolders.slice()
      arr.push({ path: pth, name: pth.split("/").pop() })
      rail.newFolders = arr
    } }
  }
  function scanFolders() {
    newFolders = []
    var home = Quickshell.env("HOME")
    var roots = remoteOffered
      ? "ls -dt " + home + "/work/lovable " + home + "/work/lovable.*/ 2>/dev/null | sed 's:/*$::'"
      : "ls -dt " + home + "/personal/*/ 2>/dev/null | sed 's:/*$::'"
    var cmd = "{ " + roots + "; zoxide query -l 2>/dev/null | head -80; } | awk 'NF && !seen[$0]++'"
    folderScan.command = ["sh", "-c", cmd]
    folderScan.running = true
  }
  // Sessions living in a folder (live + asleep), for pane 2.
  function sessionsIn(path) {
    var out = []
    if (!agentd) return out
    for (var i = 0; i < agentd.sessions.length; i++) {
      var sess = agentd.sessions[i]
      if (sess.cwd === path) out.push(sess)
    }
    return out
  }
  // Rows for pane 2: existing sessions first, then "new session".
  readonly property var newWhichRows: {
    if (!newFolder.length) return []
    var rows = sessionsIn(newFolder).map(sess => ({ kind: "resume", sess: sess }))
    for (var i = 0; i < newOrphans.length; i++)
      rows.push({ kind: "adopt", id: newOrphans[i].id, stamp: newOrphans[i].stamp })
    rows.push({ kind: "new" })
    return rows
  }
  // Pane 3 binds a plan while spawning or rebinds the selected live session.
  // Both paths share the same scan, rows, filter, and keyboard handling.
  property var newSpawnPending: null
  property var newPlans: []
  Process {
    id: planScan
    running: false
    stdout: SplitParser { onRead: data => {
      var f = String(data).trim()
      if (!f.length) return
      var arr = rail.newPlans.slice()
      arr.push(f.split("/").pop().replace(/\.md$/, ""))
      rail.newPlans = arr
    } }
  }
  function scanPlans() {
    newPlans = []
    planScan.command = ["sh", "-c",
      "ls -t \"$HOME/personal/notes/storage/plans\"/*.md 2>/dev/null"]
    planScan.running = true
  }
  readonly property var newPlanRows: {
    var f = newFilter.toLowerCase()
    var rows = []
    for (var i = 0; i < newPlans.length; i++)
      if (!f.length || newPlans[i].toLowerCase().indexOf(f) >= 0) rows.push({ slug: newPlans[i] })
    rows.push({ newPlan: true }, { none: true })
    return rows
  }
  readonly property int newPlanWinStart: Math.max(0, Math.min(newCur - 11, newPlanRows.length - 12))
  function activatePlan(row) {
    if (!row || !agentd || !newSpawnPending) return
    if (row.newPlan) {
      newMode = "plan-new"
      newInput.text = ""
      Qt.callLater(rail.enterInsert)
      return
    }
    if (newSpawnPending.rebind) {
      _planRebindPending = true
      _planRebindSid = newSpawnPending.session
      _planRebindSlug = row.none ? "" : row.slug
      agentd.send({ type: "set_plan", session: _planRebindSid, plan: _planRebindSlug })
      closeNew()
      return
    }
    var msg = newSpawnMsg(newSessionName(newFolder))
    if (!row.none) msg.plan = row.slug
    agentd.send(msg)
    closeNew()
  }
  // One spawn-message builder for every pane-3 path. Profile is inferred from
  // the folder: the main lovable checkout hosts THE orchestrator, worktrees
  // host workers — the daemon default ("coding") is wrong for both and spawned
  // role-less mongrels.
  function newSpawnMsg(sid) {
    var msg = { type: "spawn", session: sid, cwd: newFolder }
    if (newSpawnPending && newSpawnPending.adoptId) msg.adoptId = newSpawnPending.adoptId
    var home = Quickshell.env("HOME")
    if (newFolder === home + "/work/lovable") msg.profile = "lovable-orchestrator"
    else if (newFolder.indexOf(home + "/work/lovable.") === 0) msg.profile = "lovable-worker"
    return msg
  }
  function submitPlanDescription(description) {
    var text = String(description || "").trim()
    if (!text.length || !agentd || !newSpawnPending) return
    var sid = newSpawnPending.session || newSessionName(newFolder)
    if (!newSpawnPending.rebind) {
      agentd.send(newSpawnMsg(sid))
    }
    agentd.enqueue(sid, "/plan-ticket " + text)
    closeNew()
  }
  function openPlanBinding() {
    if (!agentd || !selectedRaw) return
    var cwd = ""
    for (var i = 0; i < agentd.sessions.length; i++)
      if (agentd.sessions[i].id === selectedRaw || agentd.sessions[i].name === selectedRaw) {
        cwd = agentd.sessions[i].cwd || ""; break
      }
    newOpen = true; newMode = ""; newFolder = cwd; newFilter = ""; newCur = 0
    newSpawnPending = { rebind: true, session: selectedRaw }
    scanPlans()
    requestFocus()
  }
  readonly property var newFolderRows: {
    var f = newFilter.toLowerCase()
    // A typed PATH (~/x or /x) becomes a pickable row — folders outside the
    // scope roots are one keystroke away instead of unreachable.
    if (f.charAt(0) === "~" || f.charAt(0) === "/") {
      var home = Quickshell.env("HOME")
      var pth = newFilter.replace(/^~/, home)
      var rows = newFolders.filter(d => d.path.toLowerCase().indexOf(pth.toLowerCase()) === 0)
        .map(d => ({ path: d.path, name: d.path.indexOf(home) === 0 ? "~" + d.path.slice(home.length) : d.path }))
      if (!rows.some(d => d.path === pth)) rows.push({ path: pth, name: newFilter, typed: true })
      return rows
    }
    if (!f.length) return newFolders
    return newFolders.filter(d => d.name.toLowerCase().indexOf(f) >= 0 || d.path.toLowerCase().indexOf(f) >= 0)
  }
  // The visible window FOLLOWS the cursor (a fixed first-12 slice let j walk
  // the selection off-stage).
  readonly property int newWinStart: Math.max(0, Math.min(newCur - 11, newFolderRows.length - 12))
  function openNew()  {
    newOpen = true
    newMode = ""   // folder-first; "remote" only via r on the work instance
    newFolder = ""; newCur = 0; newFilter = ""
    scanFolders()
    requestFocus()
  }
  // Orphaned pi transcripts in the folder — conversations agentd forgot
  // (crashes, stops). Offered as resumable so nothing is stranded.
  property var newOrphans: []
  Process {
    id: orphanScan
    running: false
    stdout: SplitParser { onRead: data => {
      var f = String(data).trim()
      if (!f.length) return
      var stem = f.split("/").pop().replace(/\.jsonl$/, "")
      // pi's session id is the part AFTER the timestamp prefix — adopting the
      // full stem made pi "create a new session with that id" (empty session).
      var us = stem.indexOf("_")
      var id = us >= 0 ? stem.slice(us + 1) : stem
      var owned = false
      if (rail.agentd) for (var i = 0; i < rail.agentd.sessions.length; i++) {
        var ss = rail.agentd.sessions[i]
        if (ss.ident === id || ss.name === id) { owned = true; break }
      }
      if (!owned) {
        var a = rail.newOrphans.slice()
        a.push({ id: id, stamp: stem.slice(0, 19) })
        rail.newOrphans = a
      }
    } }
  }
  function pickFolder(path) {
    newFolder = path
    newCur = 0
    newOrphans = []
    var enc = "--" + path.replace(/^\/+|\/+$/g, "").replace(/\//g, "-") + "--"
    orphanScan.command = ["sh", "-c",
      "ls -t \"$HOME/.pi/agent/sessions/" + enc + "\"/*.jsonl 2>/dev/null | head -5"]
    orphanScan.running = true
  }
  function newSessionName(path) {
    // dir basename; suffix -2, -3… when taken (any scope's roster counts).
    var base = path.split("/").pop().toLowerCase()
    var taken = {}
    if (agentd) for (var i = 0; i < agentd.sessions.length; i++) taken[agentd.sessions[i].name] = true
    if (!taken[base]) return base
    for (var n = 2; n < 100; n++) if (!taken[base + "-" + n]) return base + "-" + n
    return base
  }
  function activateWhich(row) {
    if (!row) return
    if (row.kind === "resume" && agentd) {
      activeRaw = row.sess.rawName || row.sess.id || row.sess.name
      rosterOverride = false
      Qt.callLater(rail.enterInsert)
      closeNew()
    } else if ((row.kind === "adopt" || row.kind === "new") && agentd) {
      // Spawning waits one more beat: pane 3 asks about a plan first.
      newSpawnPending = { adoptId: row.kind === "adopt" ? row.id : "" }
      newFilter = ""; newCur = 0
      scanPlans()
    }
  }
  function closeNew() { newOpen = false; newMode = ""; newFolder = ""; newFilter = ""; newSpawnPending = null; exitInsert() }
  function createSession(name) {
    var n = String(name || "").trim()
    if (!n) return
    if (newMode === "remote") {
      vmWt.command = ["vm-wt", n]
      vmWt.running = true
    } else if (agentd) {
      agentd.send({ type: "spawn", session: n.toLowerCase(),
                    cwd: scopeMode === "work" ? Quickshell.env("HOME") + "/work/lovable"
                                              : Quickshell.env("HOME") + "/personal" })
    }
    closeNew()
  }
  Process { id: vmWt; running: false }
  // Per-session reading position: the message key you were parked on, remembered only when
  // you had actually scrolled away from the live edge. Switching back restores it; a session
  // you were following (or have never opened) still lands on its newest message.
  property var _seenAt: ({})
  property var _viewFor: ({})   // sid -> "chat" | "files": the panel you left it on
  property string _prevSelected: ""
  property bool _restoring: false

  onSelectedRawChanged: {
    rememberRecent(selectedRaw)
    rememberSelection(selectedRaw)
    _ensureChanges()
    if (hinting) cancelHints("session-switch")   // hint mode is per-row; a session switch orphans it
    if (_prevSelected) {
      var m = _seenAt
      if (feedScroll.mode === "free" && cur >= rSize && cursorFeedKey) m[_prevSelected] = cursorFeedKey
      else delete m[_prevSelected]          // was following → follow again next time
      _seenAt = m
      var vw = _viewFor; vw[_prevSelected] = view; _viewFor = vw
    }
    _prevSelected = selectedRaw
    // Restore the panel (chat/files) this session was last viewed on.
    view = _viewFor[selectedRaw] || "chat"
    _feedReset = true
    // Report the rebuild, don't just do it: synced() is what consumes a pending jump, and
    // it was only ever reached from the stream debounce. Switching to an IDLE session on a
    // quiet daemon produced no further ticks, so the jump queued below never ran at all —
    // the feed sat wherever the last session left it.
    Qt.callLater(rail._resyncFeed)
    // Only restore a saved spot on a session that is NOT working. A streaming session
    // should track its live edge — parking you where you last read means "no live follow"
    // on exactly the session you switched to in order to watch it.
    var busy = false
    for (var b = 0; b < (agentd ? agentd.sessions.length : 0); b++)
      if (agentd.sessions[b].id === selectedRaw) { busy = agentd.sessions[b].status === "streaming"; break }
    var want = busy ? "" : _seenAt[selectedRaw]
    if (want) {
      // Park the anchor and let onGroupedFeedChanged land on it once the transcript arrives.
      cursorFeedKey = want
      _restoring = true
      feedScroll.hold()
    } else {
      _restoring = false
      feedScroll.toEnd()
    }
    if (agentd) agentd.select(selectedRaw)
    // Live-follow: land nvim in the session's worktree (+ plan) on open AND on
    // every switch, so the editor always tracks the session you're viewing.
    // First switch retries (nvim's RPC socket may not be up yet); after nvim has
    // answered once, land EXACTLY once per switch — the 3x retry re-ran cd +
    // dashboard three times and the buffer visibly blinked on every session change.
    if (selectedRaw) {
      if (_landed) rail.landNvim(selectedRaw)
      else { landTimer.n = 0; landTimer.restart() }
    }
  }

  // Live-follow: the agent's edits open in nvim as they happen. Driven from HERE, not
  // the nvim module — the rail sees every scope's events (a VM ticket lives on another
  // daemon than nvim's own client) and owns the remote→mirror path mapping. Policy
  // (don't yank the user off their own file, resolve the hunk line, debounce) stays in
  // lua where the editor state lives.
  // Watching a session includes watching the workers it dispatched: follow
  // accepts edits from the selected session OR any session whose parent chain
  // reaches it (the parent-view was silently ignoring its child's edits).
  // Sessions are addressed by NAME in some events and by ID in others; an id-only
  // lookup silently resolved no cwd and the follow was dropped (a parent watching a
  // child saw nothing). Match either.
  function _sessionOf(sid) {
    if (!agentd || !sid) return null
    for (var i = 0; i < agentd.sessions.length; i++) {
      var ss = agentd.sessions[i]
      if (ss.id === sid || ss.name === sid) return ss
    }
    return null
  }
  function _sessionCwdOf(sid) {
    var ss = _sessionOf(sid)
    return ss ? String(ss.cwd || "") : ""
  }
  function _followsSelected(sid) {
    if (sid === selectedRaw) return true
    var hops = 0, cur = sid
    while (cur && hops < 4) {
      var parent = ""
      for (var i = 0; i < agentd.sessions.length; i++)
        if (agentd.sessions[i].name === cur || agentd.sessions[i].id === cur) {
          parent = String(agentd.sessions[i].parent || ""); break
        }
      if (!parent) return false
      if (parent === selectedRaw) return true
      cur = parent; hops++
    }
    return false
  }
  Connections {
    target: rail.agentd
    function onEditHunk(sid, path, line) {
      if (!rail._followsSelected(sid) || !rail.nvimSock.length) return
      var cwd = rail._sessionCwdOf(sid)
      if (!cwd) return
      var lcwd = rail._localPath(cwd)
      var p = rail._localPath(String(path))
      if (p.charAt(0) !== "/") p = lcwd + "/" + p
      rail.agentd.refreshChanges(sid, lcwd)
      Quickshell.execDetached(["nvim", "--server", rail.nvimSock, "--remote-expr",
        'v:lua.require("cockpit").follow_remote("' + lcwd + '","' + p + '", '
        + (rail.focused ? 'v:true' : 'v:false') + ', ' + line + ') . execute("HunkSignsRefresh")'])
    }
    function onEditSeen(sid, path, needleB64) {
      if (!rail._followsSelected(sid) || !rail.nvimSock.length) return
      var cwd = rail._sessionCwdOf(sid)
      if (!cwd) return
      var lcwd = rail._localPath(cwd)
      var p = rail._localPath(String(path))
      if (p.charAt(0) !== "/") p = lcwd + "/" + p     // pi may report worktree-relative
      Quickshell.execDetached(["nvim", "--server", rail.nvimSock, "--remote-expr",
        'v:lua.require("cockpit").follow_remote("' + lcwd + '","' + p + '", '
        + (rail.focused ? 'v:true' : 'v:false') + ', v:null, "' + String(needleB64 || "") + '")'])
    }
  }

  // Changed files for the selected session (agentd working-tree diff).
  readonly property var changesList:
    !live ? mockChanges
          : ((agentd && agentd.changesGen >= 0 && selectedRaw) ? agentd.changesFor(selectedRaw) : [])
  readonly property string changesCwd:
    (agentd && selectedRaw) ? agentd.changesCwdFor(selectedRaw) : ""

  function activate(i) {
    if (i >= 0 && i < rosterList.length)
      activeRaw = rosterList[i].rawName || rosterList[i].name
  }
  // Per-group expand state, keyed by the row's stable identity (see groupedFeed.key).
  property var expandedGroups: ({})
  function toggleGroup(i) {
    var e = Object.assign({}, expandedGroups)
    e[i] = !e[i]
    expandedGroups = e
  }
  function toggleGroupKey(k) { toggleGroup(k) }   // string-keyed groups (turn activity)
  // Focus follows whichever field is VISIBLE: with a question up, the composer is
  // hidden and typing belongs to the ask, so `i` must land there instead.
  readonly property bool askWantsText: pendingAsk && (pendingAsk.method === "input" || pendingAsk.method === "editor")
  property bool askDeferred: false
  function enterInsert() {
    if (pendingAsk && !askDeferred && !askWantsText) { exitInsert(); return }
    insert = true
    if (newOpen && newMode !== "") newInput.forceActiveFocus()
    else if (askWantsText && !askDeferred) askInput.forceActiveFocus()
    else composerInput.forceActiveFocus()
  }
  function exitInsert() {
    insert = false
    composerInput.focus = false
    if (askWantsText) askInput.focus = false
    rail.forceActiveFocus()
  }

  // Tab toggles the main area between the chat feed and the changed-files view.
  Keys.onTabPressed: (e) => {
    if (!insert) {
      view = (view === "chat") ? "files" : "chat"
      if (cur >= rSize) cur = rSize          // land on the new view's first item
      cur = Math.max(0, Math.min(cur, navTotal - 1))
    }
    e.accepted = true
  }

  function curItem() {
    var l = curLocal()
    if (curSection() === "roster") return rosterList[l]
    return view === "files" ? changesList[l] : groupedFeed[l]
  }
  // Enter/o: act on the item under the cursor (session→select, file→open,
  // edit-msg→open, cmd-msg→copy).
  function activateCur() {
    var l = curLocal()
    if (curSection() === "roster") {
      activate(l)
      // Selecting a session means you're about to TALK to it: the roster compacts
      // and you land in the composer directly (insert) — j/k browsing is one Esc away.
      rosterOverride = false
      Qt.callLater(rail.enterInsert)
      return
    }
    if (view === "files") {
      var cf = changesList[l]
      if (cf) openInNvim(cf.path)
    } else {
      var it = groupedFeed[l]
      if (it && it.kind === "user" && compactUserMessage(it.text)) {
        toggleGroupKey("user-" + (it.key || l))
        return
      }
      var edits = activityFileRefs(it)
      if (edits.length === 1) { openFileRef(edits[0]); return }
      if (edits.length > 1) { startFileSelection(edits, "turn-" + (it.key || l)); return }
      var refs = cardFileRefs(it)
      if (refs.length === 1) { openFileRef(refs[0]); return }
    }
  }
  function toggleCurBash() {
    if (view !== "chat" || cur < rSize) return
    var l = curLocal(), it = groupedFeed[l]
    if (it && turnBashItems(it.items).length)
      toggleGroupKey("turn-" + (it.key || l))
  }
  // Is the cursor'd feed card at least partly in the viewport?
  // j/k only move the cursor. ListView keeps it on screen via its native highlight
  // range (currentIndex + ApplyRange + preferredHighlightBegin/End on feedView) —
  // no contentY math anywhere. For a message taller than the panel, wheel-scroll to
  // read the rest; j/k move card-to-card.
  function moveDown() {
    if (cur < rSize && rosterExpanded) { cur = Math.min(cur + 1, rSize - 1); return }   // stay in roster
    cur = Math.min(cur + 1, navTotal - 1)
  }
  function moveUp() {
    if (cur < rSize) { cur = Math.max(cur - 1, 0); return }   // stay in roster
    cur = Math.max(cur - 1, rSize)   // Ctrl+k returns to the roster
  }

  // Blink probes (debug): delegate/dot creations — streaming must not grow these.
  property int probeCardCreates: 0
  property int probeDotCreates: 0
  property int probeFullResets: 0
  property int probeActCreates: 0
  // Ground-truth key trace (debug): what key arrived, and what state met it.
  property var keyLog: []
  function _klog(e) {
    var l = keyLog.slice(-7)
    l.push({ k: e.key, t: String(e.text || ""), m: e.modifiers, hint: hinting, yank: yankMode, ins: insert, cur: cur })
    keyLog = l
  }
  // ── input dispatch ──────────────────────────────────────────────────────────
  // ONE derived mode + one dispatcher. Every key walks the same visible chain:
  // global chords → insert guard → hint/yank → new-session → ask → normal. Each
  // key*() returns true when it consumed the key; false falls through, exactly
  // like the old else-if ladder — but each mode is now a named function and the
  // active mode is observable (railState.im), so a shadowed binding can't hide.
  readonly property string imode:
      (insert && (!pendingAsk || askDeferred || askWantsText)) ? "insert"
    : (pendingAsk && !askWantsText)                         ? "ask"
    : hinting                                    ? (yankMode ? "yank" : "hint")
    : (newOpen && newMode === "")                ? "new"
    : pendingAsk                                 ? "ask"
    : "normal"

  // Chords that work from EVERY mode, insert included (the composer doesn't
  // consume them, so they bubble up here).
  function keyGlobal(e) {
    var ctrl = (e.modifiers & Qt.ControlModifier)
    // The stale-ask notice advertises C-d while the composer is focused — its
    // whole point is "type your answer instead", so it must work in insert.
    if (ctrl && e.key === Qt.Key_D && staleAsk) { dismissStaleAsk(); return true }
    if (ctrl && e.key === Qt.Key_O && openPendingAskUrl()) return true
    if (ctrl && e.key === Qt.Key_S) {
      requestScopeMode(scopeMode === "work" ? "personal" : "work")
      return true
    }
    // Ctrl+T = the in-app Super+T: open the roster and park on the active row;
    // pressed again while parked, put it away and return to the composer.
    if (ctrl && e.key === Qt.Key_T) {
      if (rosterExpanded && !insert && cur < rSize) {
        rosterOverride = false
        Qt.callLater(rail.enterInsert)
      } else {
        focusRoster()
      }
      return true
    }
    return false
  }

  // Hint/yank mode: a label letter acts, Esc cancels, a lone modifier is NOT a
  // choice (a reflexive Ctrl used to kill the mode before the labels were seen);
  // any other key cancels and falls through to do its normal thing.
  function keyHint(e) {
    if (e.key === Qt.Key_Escape) { cancelHints("esc"); return true }
    if (e.text && /^[a-z]$/.test(e.text)) { hintKey(e.text); return true }
    if (e.key === Qt.Key_Control || e.key === Qt.Key_Shift || e.key === Qt.Key_Alt || e.key === Qt.Key_Meta) return true
    cancelHints("other-key:" + e.key)
    return false
  }

  // New-session panel: l/r pick the kind (then the input takes over in insert);
  // everything else is swallowed while choosing. Esc closes in any phase.
  function keyNew(e) {
    if (e.key === Qt.Key_Escape) {
      if (newSpawnPending && newSpawnPending.rebind) { closeNew(); return true }
      if (newSpawnPending) { newSpawnPending = null; newFilter = ""; newCur = 0; return true }  // back to pane 2
      if (newFolder.length) { newFolder = ""; newCur = 0; return true }  // back to folders
      closeNew(); return true
    }
    // Remote (VM worktree) stays behind r on the work instance.
    if (remoteOffered && newFolder === "" && e.key === Qt.Key_R && !newFilter.length) {
      newMode = "remote"; Qt.callLater(rail.enterInsert); return true
    }
    if (newMode === "remote" || newMode === "plan-new") return false
    var rows = newSpawnPending ? newPlanRows : newFolder.length ? newWhichRows : newFolderRows
    if (e.key === Qt.Key_Down || ((newFolder.length || newSpawnPending) && e.key === Qt.Key_J)) { newCur = Math.min(Math.max(0, rows.length - 1), newCur + 1); return true }
    if (e.key === Qt.Key_Up || ((newFolder.length || newSpawnPending) && e.key === Qt.Key_K))   { newCur = Math.max(0, newCur - 1); return true }
    if (!newFolder.length && !newSpawnPending && e.key === Qt.Key_Tab) {
      var completion = newFolderRows[newCur]
      if (completion) {
        var home = Quickshell.env("HOME")
        newFilter = completion.path.indexOf(home) === 0 ? "~" + completion.path.slice(home.length) : completion.path
        newCur = 0
      }
      return true
    }
    if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
      if (newSpawnPending) activatePlan(newPlanRows[newCur])
      else if (!newFolder.length) { var d = newFolderRows[newCur]; if (d) pickFolder(d.path) }
      else activateWhich(newWhichRows[newCur])
      return true
    }
    // Folder + plan panes: type to fuzzy-filter, backspace edits.
    if (!newFolder.length || newSpawnPending) {
      if (e.key === Qt.Key_Backspace) { newFilter = newFilter.slice(0, -1); newCur = 0; return true }
      if (e.text && e.text.length === 1 && e.text >= " ") { newFilter += e.text; newCur = 0; return true }
    }
    return true
  }

  // A pending question owns its keys: y/n (confirm), 1–9 (select), i (type a
  // reply), esc (cancel), t (cancel + say what you actually think). j/k fall
  // through so the chat still scrolls under the card.
  function keyAsk(e) {
    var pm = pendingAsk.method
    if (e.key === Qt.Key_Escape) { answerAsk({ cancelled: true }); return true }
    if (e.key === Qt.Key_T && !(e.modifiers & Qt.ControlModifier)) {
      answerAsk({ cancelled: true, discussing: true })
      Qt.callLater(rail.enterInsert)
      return true
    }
    if (pm === "confirm") {
      if (e.key === Qt.Key_Y) { answerAsk({ confirmed: true });  return true }
      if (e.key === Qt.Key_N) { answerAsk({ confirmed: false }); return true }
    } else if (pm === "select" && pendingAsk.options) {
      var d = e.key - Qt.Key_0
      if (d >= 1 && d <= Math.min(9, pendingAsk.options.length)) { answerAsk({ value: pendingAsk.options[d - 1] }); return true }
    } else if (pm === "input" || pm === "editor") {
      if (e.key === Qt.Key_I) { enterInsert(); return true }
    }
    return false
  }

  function keyNormal(e) {
    var ctrl = (e.modifiers & Qt.ControlModifier)
    var shift = (e.modifiers & Qt.ShiftModifier)
    if (ctrl && (e.key === Qt.Key_Return || e.key === Qt.Key_Enter)) {
      toggleCurBash()
      return true
    }
    // Ctrl+j → jump into the main view; Ctrl+k → back to the roster top.
    if (ctrl && e.key === Qt.Key_J) { cur = (rSize < navTotal) ? rSize : Math.max(0, navTotal - 1); return true }
    if (ctrl && e.key === Qt.Key_K) { cur = 0; return true }
    switch (e.key) {
    case Qt.Key_I:      enterInsert(); return true
    case Qt.Key_Escape:
      // Shift+Esc = surgical: kill only the RUNNING TOOL CALL (turn survives).
      // Esc = interrupt, everywhere: abort the open session's turn if it is
      // running; idle keeps the old escape-to-nvim.
      if (shift) {
        if (rail.featuredStreaming && rail.agentd && rail.selectedRaw) rail.agentd.abortTool(rail.selectedRaw)
        return true
      }
      if (rail.featuredStreaming && rail.agentd && rail.selectedRaw) rail.agentd.interrupt(rail.selectedRaw)
      else rail.focusNvim()
      return true
    case Qt.Key_H:      rail.focusNvim(); return true
    case Qt.Key_J:      rail.moveDown(); return true
    case Qt.Key_K:      rail.moveUp(); return true
    case Qt.Key_G:      cur = shift ? navTotal - 1 : 0; return true
    case Qt.Key_F:      rail.startHints(); return true          // vimium-style link hints
    case Qt.Key_Y:
      if (shift) {                                              // Y = whole message, no mode
        if (rail.view === "chat" && rail.cur >= rail.rSize)
          rail.copyText(String(rail.feedCopyTarget(rail.groupedFeed[rail.cur - rail.rSize]) || ""))
      } else {
        rail.startYank()                                        // yank-hints (yy = whole message)
      }
      return true
    case Qt.Key_N:      rail.openNew(); return true             // new session
    case Qt.Key_W:
      if (shift) { rail.requestScopeMode(rail.scopeMode === "work" ? "personal" : "work"); return true }
      break
    case Qt.Key_P:
      if (shift) { rail.openPlanBinding(); return true }
      break
    case Qt.Key_X:
      // In the roster x kills the aimed row; in the feed it kills the selected session
      // and returns to the most recently visited surviving one. Esc interrupts a turn.
      if (rail.curSection() === "roster") {
        var row = rail.rosterList[rail.curLocal()]
        if (row) rail.stopSession(row.rawName || row.name)
      } else {
        rail.stopSession(rail.selectedRaw)
      }
      return true
    case Qt.Key_O: case Qt.Key_Return: case Qt.Key_Enter:
      activateCur(); return true
    }
    return false
  }

  Keys.onPressed: (e) => {
    _klog(e)
    if (keyGlobal(e)) { e.accepted = true; return }
    if (fileSelectOpen && keyFileSelection(e)) { e.accepted = true; return }
    // Insert: the focused input owns the keyboard — except a blocking confirm/
    // select ask, which hides the composer, so its keys must still land here.
    if (insert && (!pendingAsk || askDeferred || askWantsText)) return
    if (hinting && keyHint(e)) { e.accepted = true; return }
    if (newOpen && keyNew(e)) { e.accepted = true; return }
    if (pendingAsk && keyAsk(e)) { e.accepted = true; return }
    if (keyNormal(e)) e.accepted = true
  }
  // A feed refresh (stream update / reload) can shrink navTotal below cur, so
  // the cursor points past the last message and nothing highlights. Re-clamp.
  onNavTotalChanged: if (cur > navTotal - 1) cur = Math.max(0, navTotal - 1)

  // Cursor moves report to FeedScroll, which reveals the row (or re-pins on the last).
  onCurChanged: {
    if (fileSelectOpen) closeFileSelection()
    if (hinting) cancelHints("cur-move")   // any cursor move invalidates the labeled row
    _anchorCursor()
    if (view === "files" && cur >= rSize) changesView.positionViewAtIndex(cur - rSize, ListView.Contain)
    else if (view === "chat" && cur >= rSize)
      feedScroll.cursorMoved(cur - rSize, cur >= navTotal - 1)
  }

  readonly property string scrollMode: feedScroll.mode
  // The actual content under the cursor, so a test can verify WHICH row it is instead of
  // trusting the anchor variable (which would only ever agree with itself).
  function curRowText() {
    var it = curItem()
    if (!it) return ""
    if (curSection() === "roster") return String(it.rawName || it.name || "")
    if (view === "files") return String(it.path || "")
    if (it.kind === "turn") {
      var its = it.items || []
      for (var i = its.length - 1; i >= 0; i--)
        if (its[i].text) return String(its[i].text).slice(0, 48)
      return "turn"
    }
    return String(it.text || "").slice(0, 48)
  }
  // Nav driven from the IPC, for test/rail-nav.sh.
  // Walk the realized delegate under the cursor and pull its prose Text.text —
  // the ONLY view of what the badge pipeline actually rendered (test probe).
  function probeProse() {
    if (view !== "chat" || cur < rSize) return ""
    var idx = cur - rSize, c = feedView.contentItem.children
    for (var i = 0; i < c.length; i++) {
      if (c[i].rowIndex !== idx) continue
      var out = []
      ;(function walk(o) {
        if (!o) return
        if (o.text !== undefined && String(o.text).length > 0) out.push(String(o.text))
        var ch = o.children || []
        for (var j = 0; j < ch.length; j++) walk(ch[j])
      })(c[i])
      return out.join("\n---\n")
    }
    return ""
  }
  function debugNav(k) {
    if (k === "j") moveDown()
    else if (k === "k") moveUp()
    else if (k === "g") cur = 0
    else if (k === "G") cur = Math.max(0, navTotal - 1)
    else if (k === "enter") activateCur()
    else if (k === "tab") { view = (view === "chat") ? "files" : "chat"; if (cur >= rSize) cur = rSize }
    else if (k === "i") enterInsert()
    // Ask answers go through the SAME path as the real keys — but only when the key
    // handler would accept them, so a test faithfully exercises the insert guard too.
    else if (k === "y" || k === "n") {
      if (pendingAsk && !askDeferred && !(insert && askWantsText)) answerAsk({ confirmed: k === "y" })
    }
    else if (k === "x") {
      if (curSection() === "roster") {
        var row = rosterList[curLocal()]
        if (row) stopSession(row.rawName || row.name)
      } else {
        stopSession(selectedRaw)
      }
    }
    else if (k === "hint") startHints()
    else if (k === "yank") startYank()
    else if (k.indexOf("hintkey:") === 0) hintKey(k.slice(8))
    else if (k === "esc") {
      if (askDeferred) {
        askDeferred = false
        if (askWantsText) Qt.callLater(enterInsert)
        else exitInsert()
      } else if (featuredStreaming && agentd && selectedRaw) agentd.interrupt(selectedRaw)
      else if (insert) exitInsert()
    }
    else if (k === "killtool") {
      if (featuredStreaming && agentd && selectedRaw) agentd.abortTool(selectedRaw)
    }
  }
  // The rail's own ground: one step darker than the editor side (Theme.bgDim), so the
  // two panes read as distinct layers without a divider doing the work.
  Rectangle { anchors.fill: parent; color: Theme.bgDim; z: -1 }

  // Daemon health banner (boot self-check failed): the whole scope is broken, not
  // one session — pin it above everything so it can't be scrolled away or missed.
  Rectangle {
    readonly property string h: {
      if (!rail.agentd) return ""
      rail.agentd.healthGen
      return rail.agentd.healthSummary()
    }
    visible: h.length > 0
    anchors { left: parent.left; right: parent.right; top: parent.top }
    height: visible ? healthText.implicitHeight + 16 : 0
    color: Theme.red
    z: 30
    Text {
      id: healthText
      anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 14; rightMargin: 14 }
      text: "⚠ " + parent.h
      color: Theme.bg
      font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta; font.bold: true
      wrapMode: Text.WordWrap; maximumLineCount: 3; elide: Text.ElideRight
    }
  }

  // Incremental feed model. `groupedFeed` is a fresh JS ARRAY every time stream data
  // lands, and ListView cannot diff arrays — assigning one destroys and rebuilds every
  // delegate (re-parsing all the markdown), which at the 120ms debounce cadence is the
  // ~8x/sec flicker during a long turn. So reconcile into a ListModel instead: rows are
  // matched by a cheap signature, and only the row that actually changed is written, so
  // the delegates persist and their bindings just update in place.
  ListModel { id: feedModel; dynamicRoles: true }
  property bool _feedReset: false     // session switch → rebuild rather than reconcile
  function _turnSig(t) {
    if (!t) return ""
    if (t.kind !== "turn") return t.kind + "|" + String(t.text || t.command || "").length
    var its = t.items || []
    var last = its.length ? its[its.length - 1] : null
    return "turn|" + its.length + "|" +
      (last ? (String(last.kind) + String(last.text || last.command || "").length) : "")
  }
  // Row identity: turns carry a stable key; keyless rows (live pushes, echoes)
  // fall back to kind+text, which never mutates for those kinds.
  function _feedKey(t) {
    if (!t) return ""
    return t.key ? ("k:" + t.key) : (String(t.kind) + ":" + String(t.text || t.command || "").slice(0, 80))
  }
  function syncFeedModel() {
    var arr = groupedFeed
    if (_feedReset) {
      _feedReset = false
      feedModel.clear()
      for (var a = 0; a < arr.length; a++)
        feedModel.append({ d: arr[a], sig: _turnSig(arr[a]), k: _feedKey(arr[a]) })
      return
    }
    _reconcileKeyed(feedModel, arr, _feedKey, _turnSig)
  }

  // Per-row geometry of the realized feed rows, for asserting that cards do not OVERLAP.
  // "Cards on top of each other" is invisible to every other probe — the model, the cursor
  // and the mode all read as correct while the rows are drawn over one another — so read the
  // delegates' own y/height instead of reasoning about which child under-reports its size.
  function feedGeom() {
    var out = []
    for (var i = 0; i < feedModel.count; i++) {
      var it = feedView.itemAtIndex(i)
      if (!it) continue
      out.push({ i: i, y: Math.round(it.y), h: Math.round(it.height),
                 ih: Math.round(it.implicitHeight), ch: Math.round(it.cardHeight) })
    }
    return out
  }

  // Distance from the live edge, so "it isn't following" is a number instead of an opinion.
  function feedScrollState() {
    return { mode: feedScroll.mode,
             behind: Math.round(feedView.originY + feedView.contentHeight - feedView.height - feedView.contentY),
             cy: Math.round(feedView.contentY), ch: Math.round(feedView.contentHeight),
             h: Math.round(feedView.height), count: feedModel.count }
  }

  // Rebuild the feed rows and tell the scroll machine they are in. Always paired: a sync
  // without the report leaves a queued jump waiting for an event that may never come.
  function _resyncFeed() { syncFeedModel(); feedScroll.synced() }

  // --- Live feed for the selected session; mock when no daemon data yet ---
  // Debounced stream updates: rebuilding the whole feed model on every token
  // blocks the UI thread and stutters animations (the orb) + scrolling. Coalesce
  // rapid bumps into ~8 rebuilds/sec by depending on feedTick, not feedGen.
  property int feedTick: 0
  Timer {
    id: feedDebounce; interval: 120
    onTriggered: {
      rail.feedTick++
      rail._resyncFeed()
    }
  }
  Connections {
    target: agentd
    function onFeedGenChanged() { feedDebounce.restart() }
  }

  readonly property var feed: {
    if (!live) return mockFeed   // mock only in demo mode
    void rail.feedTick           // debounced dependency (see feedDebounce)
    // Live: the SELECTED session's own transcript (empty until loaded), read at
    // the debounced tick so rapid stream bumps don't thrash the model.
    return (agentd && selectedRaw) ? agentd.feedFor(selectedRaw) : []
  }
  readonly property var mockFeed: [
    { kind: "user",  text: "Fix tile placement so deleted shapes free their geometry." },
    { kind: "think", text: "Reviewing placement occupancy" },
    { kind: "cmd",   tool: "bash", text: "bash git branch -vv | rg '^\\*'", command: "git branch -vv | rg '^\\*'" },
    { kind: "cmd",   tool: "mcp",  text: "mcp linear linear_list_issues" },
    { kind: "cmd",   tool: "grep", text: "grep placementOccupancy" },
    { kind: "edit",  tool: "edit", file: "useComponentTiles.ts", path: "web/modules/design-system/home/hooks/useComponentTiles.ts", add: 123, del: 76 },
    { kind: "text",  text: "Excluded shapes scheduled for deletion from placement occupancy so replacements reuse vacated geometry." }
  ]

  // Fold the flat feed into cards: each user message stands alone; an agent
  // message = its tool activity plus the prose that ends it → one card. A new
  // agent card opens after each prose block (and after every user message).
  // Every row carries `key`, a stable identity from the message it came from. Row INDEX
  // is not stable: the transcript is capped to the last 60 messages, so past that each
  // new message slides the whole window and every index shifts by one.
  // A card also closes after this many tool calls. Only PROSE used to end one, so a long
  // tool-only stretch — a Playwright loop, a build chase — collapsed into a single card
  // hundreds of items tall: scrolling the chat showed nothing but that one card. Chunking
  // gives a sequence instead, and since only the newest card auto-expands, the older
  // chunks read as one-line activity summaries.
  readonly property int turnChunk: 12
  function userMessageStats(text) {
    var source = String(text || "")
    return { lines: source.length ? source.split("\n").length : 0, chars: source.length }
  }
  function compactUserMessage(text) {
    var stats = userMessageStats(text)
    return stats.lines >= 8 || stats.chars >= 800
  }
  // Fallback row key when no transcript mid exists (live pushes, streaming
  // turns): derived from CONTENT, so the key survives both index shifts and
  // the live->rebuild swap — index-based keys re-keyed whole stretches and
  // tore down every delegate below (the feed "blink").
  function _contentKey(kind, text) {
    return "c:" + kind + ":" + String(text || "").slice(0, 60)
  }
  readonly property var groupedFeed: {
    var f = feed, out = [], cur = null, acts = 0, chunked = false
    for (var i = 0; i < f.length; i++) {
      var it = f[i]
      if (it.kind === "user") {
        if (cur) { out.push(cur); cur = null; acts = 0 }
        chunked = false
        // A user message whose visible text stripped to nothing (system-reminder
        // only, or a bare sender stamp) rendered as a blank card — skip it.
        if (!String(it.text || "").trim().length) continue
        out.push({ kind: "user", text: it.text, mid: it.mid, steered: it.steered === true, sender: it.sender || "", key: it.mid || _contentKey("user", it.text) })
      } else if (it.kind === "sys") {
        // Housekeeping (compaction) gets its OWN card so it never colors the
        // neighboring turn's errors.
        if (cur) { out.push(cur); cur = null; acts = 0 }
        chunked = false
        if (!String(it.text || "").trim().length) continue
        out.push({ kind: "turn", sys: true, items: [it], key: it.mid || _contentKey(it.kind, it.text) })
      } else {
        // An empty assistant text (a turn that produced no prose — aborted mid-turn,
        // or whose only content was a tool call already shown above) rendered as a
        // blank card. Close any open card, but never open one for nothing.
        if (it.kind === "text" && !String(it.text || "").trim().length) {
          if (cur) { out.push(cur); cur = null; acts = 0; chunked = false }
          continue
        }
        if (!cur) { cur = { kind: "turn", items: [], key: it.mid || _contentKey(it.kind, it.text || it.command), contFrom: chunked }; acts = 0 }
        cur.items.push(it)
        if (it.kind === "text") { out.push(cur); cur = null; acts = 0; chunked = false }   // prose ends the card
        else {
          if (it.kind !== "think") acts++
          // A long tool run is CHUNKED (one card can't grow unbounded) — mark both
          // sides of the cut so the pieces render as one continuing turn, not as
          // finished turns that mysteriously never conclude.
          if (acts >= turnChunk) { cur.cont = true; out.push(cur); cur = null; acts = 0; chunked = true }
        }
      }
    }
    if (cur) out.push(cur)
    // Duplicate content (two "continue" rows) must not share a key — suffix
    // repeats by occurrence, which is order-stable across rebuilds.
    var seenK = {}
    for (var oi = 0; oi < out.length; oi++) {
      var bk = out[oi].key
      if (seenK[bk] === undefined) seenK[bk] = 0
      else { seenK[bk]++; out[oi].key = bk + "#" + seenK[bk] }
    }
    return out
  }

  ColumnLayout {
    anchors { top: parent.top; left: parent.left; right: parent.right; bottom: chin.top }
    anchors.margins: 0
    // Breathing room at the window's top edge — cards used to start at y=0
    // with their first line clipped against the bezel.
    anchors.topMargin: 16
    // The feed ENDS at the sheet's top — no slide-under. Sliding beneath the rounded
    // corners forced the fade to a full-opacity band across the notch zone, and that
    // band smoked the text above the sheet; ending here leaves clean ground behind
    // the corner arcs and lets the fade stay a gentle dissolve.
    anchors.bottomMargin: 0
    spacing: 0

    Crossfade {
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.leftMargin: 20; Layout.rightMargin: 20
      showSecond: rail.view === "chat"
      enterDuration: 400
      exitDuration: 350
      shift: 8

    // Files view — full changed-files list for the selected session.
    first: ListView {
      id: changesView
      anchors.fill: parent
      enabled: rail.view === "files"
      clip: true
      activeFocusOnTab: false
      model: rail.changesList
      header: Item { width: changesView.width; height: 12 }
      boundsBehavior: Flickable.StopAtBounds
      ScrollFeel { flick: changesView }
      delegate: Rectangle {
        width: changesView.width
        implicitHeight: 26
        radius: Theme.radiusSm
        readonly property bool cursor: rail.focused && !rail.insert && rail.cur === rail.rSize + index
        color: cursor ? Qt.rgba(Theme.selection.r, Theme.selection.g, Theme.selection.b, 0.6)
             : chov.hovered ? Qt.rgba(Theme.selection.r, Theme.selection.g, Theme.selection.b, 0.4) : "transparent"
        border.width: cursor ? 1 : 0
        border.color: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.35)
        HoverHandler { id: chov }
        TapHandler { onTapped: rail.clickAt(rail.rSize + index) }
        RowLayout {
          anchors { fill: parent; leftMargin: 6; rightMargin: 6 }
          spacing: 8
          Icon { name: "paintbrush"; width: 12; height: 12; color: Theme.fg_muted; Layout.alignment: Qt.AlignVCenter }
          Text { text: modelData.path; color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta; elide: Text.ElideMiddle; Layout.fillWidth: true }
          // Fixed right-aligned slots so the +/- columns line up across every row.
          Text { text: "+" + modelData.add; color: Theme.green; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
                 Layout.preferredWidth: 46; horizontalAlignment: Text.AlignRight }
          Text { text: "-" + modelData.del; color: Theme.red; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
                 Layout.preferredWidth: 40; horizontalAlignment: Text.AlignRight }
        }
      }
    }

    // Chat view — the activity feed.
    second: ListView {
      id: feedView
      anchors.fill: parent
      enabled: rail.view === "chat"
      clip: true
      spacing: 18
      model: feedModel
      boundsBehavior: Flickable.StopAtBounds
      // Realize the WHOLE feed (it is capped at feedCap=60 rows — slack-channel scale).
      // This one line is what makes scrolling exact instead of statistical: virtualized,
      // contentHeight is an estimate and every scroll-to-bottom lands on a guess, which is
      // where the old settle bursts, follow polls and repin timers all came from. The
      // sibling apps (slk-gui-proto/MessageList.qml) proved this trade years of bugs ago.
      cacheBuffer: 1000000
      // No native highlight machinery: ApplyRange re-evaluated the current item's position
      // on EVERY model change (the view yanked while streaming), so the cursor is revealed
      // explicitly in FeedScroll.cursorMoved instead — geometry is exact now.
      highlightFollowsCurrentItem: false
      highlight: null           // the delegate paints its own cursor fill
      ScrollFeel {
        flick: feedView
        onScrolled: (up) => feedScroll.userScrolled(up)
      }
      // At-rest content clears the sheet (radius + one gap); SCROLLED content slides up
      // underneath it — the header scrolls with the feed, which is the whole trick.
      header: Item { width: feedView.width; height: feedView.spacing }
      footer: Item { width: feedView.width; height: 56 }   // bottom scroll padding above the fade/pill
      // Edge fades, fixed to the view (non-delegate children of a ListView paint above
      // its content). The top one is opaque through the sheet's corner-notch zone — the
      // curve then sits on clean ground — and dissolves below it; the bottom one mirrors
      // above the composer, only while content remains below the viewport.
      Rectangle {
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: 44
        z: 2
        gradient: Gradient {
          GradientStop { position: 0.0; color: Theme.bgDim }
          GradientStop { position: 1.0; color: Qt.rgba(Theme.bgDim.r, Theme.bgDim.g, Theme.bgDim.b, 0) }
        }
      }
      Rectangle {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 44
        z: 2
        opacity: (feedView.originY + feedView.contentHeight - feedView.height - feedView.contentY) > 8 ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 150 } }
        gradient: Gradient {
          GradientStop { position: 0.0; color: Qt.rgba(Theme.bgDim.r, Theme.bgDim.g, Theme.bgDim.b, 0) }
          GradientStop { position: 1.0; color: Theme.bgDim }
        }
      }
      onCountChanged: feedScroll.contentChanged()
      // Streaming content arrived as a hard pop. Fade added rows in — short enough
      // (140ms) that it never lags the bottom-follow, and `displaced` keeps the rows
      // below from jumping when one is inserted.
      // NO add/displaced transitions. A row inside one has its geometry held by the
      // transition manager, and these cards only reach their real height AFTER their prose
      // Loader realizes (57 -> 144px) — that growth never made it back into the layout, so
      // every agent card was positioned as a 57px row and painted over the one below it.
      // (`ipc call cockpit railGeom` shows it: y jumps by 75 between rows that are 144 tall.)
      // The fade lives in the delegate instead, where it cannot touch layout.
      // Manual scrolling wins over follow-the-stream. NOTE: do NOT use
      // onMovementStarted/Ended here — Flickable emits those for PROGRAMMATIC
      // contentY changes too, so the follow timer's own scrolling would trip them.
      // `dragging` and `flicking` are user-gesture-only, so key off those.
      onDraggingChanged: dragging ? feedScroll.gestureStarted() : feedScroll.gestureEnded()
      onFlickingChanged: if (!flicking) feedScroll.gestureEnded()
      delegate: Item {
        id: turnDel
        width: feedView.width
        implicitHeight: card.implicitHeight
        // Streaming content arrived as a hard pop; fade each row in on its own (see the
        // note above on why this is not a ListView `add` transition).
        opacity: 0
        property real introBlur: 0.125
        property real introY: 4
        transform: Translate { y: turnDel.introY }
        layer.enabled: turnIntro.running
        layer.effect: MultiEffect { blurEnabled: true; blurMax: 16; blur: turnDel.introBlur }
        Component.onCompleted: { turnIntro.start(); rail.probeCardCreates++ }
        ParallelAnimation {
          id: turnIntro
          NumberAnimation { target: turnDel; property: "opacity"; from: 0; to: 1; duration: 150; easing.type: Easing.InOutQuad }
          NumberAnimation { target: turnDel; property: "introY"; from: 4; to: 0; duration: 150; easing.type: Easing.OutCubic }
          NumberAnimation { target: turnDel; property: "introBlur"; from: 0.125; to: 0; duration: 150; easing.type: Easing.InOutQuad }
        }
        property int rowIndex: index
        readonly property real cardHeight: card.height   // for the feedGeom probe
        // Capture the row's turn once: nested Repeaters shadow `model` with their
        // own model property, so model.d is only readable at the delegate root.
        readonly property var turn: model.d
        readonly property bool isUser: turnDel.turn.kind === "user"
        readonly property bool compactUser: isUser && rail.compactUserMessage(turn.text)
        readonly property string userFoldKey: "user-" + (turn.key || rowIndex)
        readonly property bool userExpanded: compactUser && rail.expandedGroups[userFoldKey] === true
        readonly property var userStats: rail.userMessageStats(isUser ? turn.text : "")
        // Housekeeping (compaction) is the SYSTEM speaking, not the agent.
        readonly property bool isSys: turnDel.turn.sys === true
        readonly property bool cursor: rail.focused && !rail.insert && rail.cur === rail.rSize + rowIndex

        Rectangle {
          id: card
          anchors { left: parent.left; right: parent.right }
          implicitHeight: cardCol.implicitHeight + 36
          radius: 14
          // Fill-only separation, verified against the reference UI by sampling it:
          // ground 10,10,10 → card 23,23,23 → inner element 31,31,31, and NO borders
          // anywhere. The step sizes carry it; an added hairline just muddies them.
          color: turnDel.cursor ? Theme.surface : Theme.bg
          border.width: (turnDel.cursor || Theme.mode === "light") ? 1 : 0
          border.color: turnDel.cursor ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.45) : Theme.hairline
          HoverHandler { id: fhov }
          TapHandler { onTapped: rail.clickAt(rail.rSize + turnDel.rowIndex) }

          Column {
            id: cardCol
            anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 18; rightMargin: 18; topMargin: 18 }
            spacing: 13

            // Turn header — the Nucleo glyph is the ONLY colored signifier;
            // the label stays neutral and a touch bigger than the body text.
            Row {
              spacing: 8
              visible: !turnDel.isSys
              Icon {
                name: turnDel.isUser ? "paper-plane-2" : "sparkle-3"
                variantSize: turnDel.isUser ? 12 : 0   // paper-plane-2--glyph--12 for "you"
                width: 16; height: 16; anchors.verticalCenter: parent.verticalCenter
                color: turnDel.isUser ? Theme.orange : Theme.electric
              }
              Text {
                text: turnDel.isUser ? (turnDel.turn.sender || "you") : "agent"
                color: Theme.fg
                font.family: Theme.fontFamily; font.pixelSize: rail.fsName; font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }
              // A steer redirected a LIVE turn — visibly different from a normal
              // prompt, so "why did it abort" has its answer in the header.
              Rectangle {
                visible: turnDel.isUser && turnDel.turn.steered === true
                implicitWidth: steerCap.implicitWidth + 12
                implicitHeight: 17; radius: 8.5
                color: "transparent"
                border.width: 1; border.color: Theme.orange
                anchors.verticalCenter: parent.verticalCenter
                Text {
                  id: steerCap; anchors.centerIn: parent
                  text: "steer"
                  color: Theme.orange
                  font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3; font.bold: true
                }
              }
            }

            // A turn with nothing VISIBLE (no events yet, or only empty thinking
            // blocks): say what's happening instead of a bare header over
            // emptiness — live turns show a spinner, ended ones say so.
            Row {
              spacing: 8
              readonly property bool blank: {
                var its = turnDel.turn.items || []
                for (var bi = 0; bi < its.length; bi++) {
                  var bit = its[bi]
                  if (bit.kind === "think" && !String(bit.text || "").trim()) continue
                  return false
                }
                return true
              }
              visible: !turnDel.isUser && blank
              Spinner {
                visible: rail.featuredStreaming
                anchors.verticalCenter: parent.verticalCenter
                running: visible; color: Theme.fg_muted; dotSize: 1.6
              }
              Text {
                text: rail.featuredStreaming ? "thinking — nothing streamed yet"
                                             : "· turn ended without visible output"
                color: Theme.fg_muted
                font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Rectangle {
              visible: turnDel.compactUser
              width: Math.min(cardCol.width, pastedTextRow.implicitWidth + 16)
              implicitHeight: 26
              radius: 7
              color: Theme.surface0
              border.width: 1
              border.color: Theme.hairline
              Row {
                id: pastedTextRow
                anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 8 }
                spacing: 6
                Icon {
                  name: "file-content"
                  width: 13; height: 13; color: Theme.orange
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  text: "Pasted text · " + turnDel.userStats.lines + " lines · " + turnDel.userStats.chars + " chars"
                  color: Theme.fg_muted
                  font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
                  anchors.verticalCenter: parent.verticalCenter
                }
                Icon {
                  name: turnDel.userExpanded ? "chevron-down" : "chevron-right"
                  width: 11; height: 11; color: Theme.fg_muted
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }

            Loader {
              active: turnDel.isUser && (!turnDel.compactUser || turnDel.userExpanded)
              visible: active
              width: cardCol.width
              sourceComponent: rail.hasImageAttachments(sourceText) ? inlineAttachmentContent : markdownContent
              property string sourceText: turnDel.isUser ? String(turnDel.turn.text || "") : ""
              property int sourceEntry: 0
              property int sourceOffset: 0
              property int rowIndex: turnDel.rowIndex
              property color bodyColor: Theme.fg
              property bool agentAuthored: false
            }

            // Status markers (compaction, retries) — inline, muted. They carry no
            // activity counts, so without this they rendered as an EMPTY agent card.
            Repeater {
              model: turnDel.isUser ? 0 : rail.turnInfos(turnDel.turn.items).length
              Text {
                width: cardCol.width
                text: rail.turnInfos(turnDel.turn.items)[index] || ""
                color: Theme.fg_muted
                font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
              }
            }

            // Thought process — visible inline. Each block shows its short header;
            // tap to reveal the full reasoning.
            Repeater {
              model: turnDel.isUser ? [] : rail.turnThinks(turnDel.turn.items)
              Loader {
                id: thoughtLoader
                width: cardCol.width
                sourceComponent: thinkRow
                opacity: 0
                property real introBlur: 0.125
                property real introY: 4
                transform: Translate { y: thoughtLoader.introY }
                layer.enabled: thoughtIntro.running
                layer.effect: MultiEffect { blurEnabled: true; blurMax: 16; blur: thoughtLoader.introBlur }
                Component.onCompleted: thoughtIntro.start()
                ParallelAnimation {
                  id: thoughtIntro
                  NumberAnimation { target: thoughtLoader; property: "opacity"; from: 0; to: 1; duration: 150; easing.type: Easing.InOutQuad }
                  NumberAnimation { target: thoughtLoader; property: "introY"; from: 4; to: 0; duration: 150; easing.type: Easing.OutCubic }
                  NumberAnimation { target: thoughtLoader; property: "introBlur"; from: 0.125; to: 0; duration: 150; easing.type: Easing.InOutQuad }
                }
                property var entry: modelData
                property string gkey: "think-" + turnDel.rowIndex + "-" + index
                property bool expanded: rail.expandedGroups[gkey] === true
              }
            }

            // Agent prose — the headline answer (each text block).
            Repeater {
              model: turnDel.isUser ? [] : rail.turnProse(turnDel.turn.items)
              Loader {
                width: cardCol.width
                property var entry: modelData
                property int entryIndex: index
                property int rowIndex: turnDel.rowIndex
                sourceComponent: proseRow
              }
            }

            Repeater {
              model: turnDel.isUser ? [] : rail.turnSys(turnDel.turn.items)
              Text {
                width: cardCol.width
                text: modelData.text || ""
                color: Theme.fg_muted
                font.family: Theme.fontFamily
                font.pixelSize: rail.fsMeta
                wrapMode: Text.WordWrap
              }
            }

            Repeater {
              model: turnDel.isUser ? [] : rail.turnUserBash(turnDel.turn.items)
              Loader {
                width: cardCol.width
                property var entry: modelData
                sourceComponent: userBashRow
              }
            }

            // Compact counts, always-visible edited files, and optional Bash details.
            Loader {
              active: !turnDel.isUser && rail.turnActivitySummary(turnDel.turn.items).length > 0
              visible: active
              width: cardCol.width
              sourceComponent: activityRow
              property var items: turnDel.isUser ? [] : rail.turnActivityItems(turnDel.turn.items)
              property string summary: active ? rail.turnActivitySummary(turnDel.turn.items) : ""
              // Keyed on the row's stable identity, not its index: a group you expanded
              // otherwise collapsed (and its neighbour opened) as the window slid.
              property string ekey: "turn-" + (turnDel.turn.key || turnDel.rowIndex)
              property bool expanded: rail.expandedGroups[ekey] === true
            }

            // Chunked mid-turn cut: say the turn continues, so a header-less next
            // chunk (and the missing ✧ recap) read as intended, not as a bug.
            Text {
              visible: !turnDel.isUser && turnDel.turn.cont === true
              text: "⋯ continues"
              color: Theme.fg_muted
              font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
            }
          }
        }
      }
    }
    }

  }



  // Chin: the bottom SHEET — roster + composer in one container, anchored to the
  // rail bottom. Bleeds 1px past the sides and one radius below the window, so only
  // the rounded TOP corners and their hairline are visible (mirror of the old top
  // sheet). The feed is bounded to chin.top, so chat rows can never bleed under it.
  Rectangle {
    id: chin
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
    // Inset from the sides so the sheet's own hairline never doubles up against the
    // term/rail divider; still bleeds one radius below the window for a square bottom.
    anchors.leftMargin: 8; anchors.rightMargin: 8
    anchors.bottomMargin: -radius
    radius: 20 + 8
    border.color: Theme.hairlineSoft; border.width: 1
    // 108 = composer + hints + padding, stable across the insert toggle. A pending
    // ask_user expands the chin to hold it, so the question takes over the input
    // instead of floating over the feed — animated so the jump is legible.
    // Height follows the content. The chin is anchored to the BOTTOM, so whatever it
    // contains — composer, ask card, new-session panel — it grows upward from a fixed
    // bottom edge with no arithmetic. (This used to be a hardcoded 108 plus per-panel
    // fudge factors, which is how the new-session card ended up overflowing.)
    clip: true
    height: chinCol.implicitHeight + 26 + radius   // 14 top pad + 12 visible bottom pad
    color: Theme.surface0

    ColumnLayout {
      id: chinCol
      // Bottom-anchored so the composer + hints stay put and the roster grows UPWARD
      // when it expands (the sheet's top edge rises; the input never moves).
      // 12 visible: with the 16px hint row the old 6px left the caps flush with
      // the window edge; 12 recenters the band on the (now 36px) nvim chin.
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 20; rightMargin: 20; bottomMargin: 12 + chin.radius }
      spacing: 10


      // Roster — inside the bottom sheet, above the composer. The chin carries the
      // card styling; this block is just the rows (or the collapsed dots glance).
      Item {
        id: rosterCard
        Layout.fillWidth: true
        // Always clip: without it, collapsing rows slide over the composer during
        // the toggle animation. The orb fits because the glance sizes to content.
        clip: true
        // The ONE geometry animation. The sheet has no Behavior of its own — its
        // height binding follows this frame-by-frame, so container and content can
        // never separate; rows are revealed by this clip and fade in slower.
        // The glance stays as the HEADER when expanded — the active session lives
        // there (big title + orb), never duplicated as a list row.
        implicitHeight: glanceCol.implicitHeight + (rail.rosterExpanded ? rosterInner.implicitHeight + 4 : 0) + 8
        Behavior on implicitHeight {
          NumberAnimation { duration: Motion.slow; easing.type: Easing.InOutQuad }
        }

        function collapsedOrbX(rowIndex) {
          var count = 0
          var rank = -1
          for (var i = 0; i < rosterModel.count; i++) {
            var data = rosterModel.get(i).d
            if ((data.depth || 0) !== 0) continue
            if (i === rowIndex) rank = count
            count++
          }
          if (rank < 0) return width
          var rightMargin = rail.featuredStreaming ? 44 : 32
          return width - rightMargin - (count * 16 + Math.max(0, count - 1) * 12) + rank * 28
        }

        // Glance = the active session's home in BOTH states: collapsed it is the
        // whole roster; expanded it becomes the header above the others-list.
        // Only the right-side status dots are collapsed-only (the list shows them).
        Item {
          id: glanceCol
          anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 4 }
          // FIXED height, sized for the orb (44px + breathing room): deriving it
          // from the row's content made the whole sheet jump every time the orb
          // entered or left. The space is reserved whether or not it's running.
          implicitHeight: 52
          // The header is the roster's handle: click to open it (and close it again).
          TapHandler {
            onTapped: rail.rosterExpanded ? rail.rosterOverride = false : rail.focusRoster()
          }
          Row {
            id: glanceName
            // Row geometry, with the pill's own 9px inset subtracted so the MARKER —
            // not the pill's border box — lands on the rows' 14px column.
            anchors { left: parent.left; leftMargin: 5; verticalCenter: parent.verticalCenter }
            spacing: 12
            // On the ORCHESTRATOR this icon is also the handover switch — it already
            // says which host runs the role, so a second pill was a duplicate. Hover
            // expands it into a labelled control; elsewhere it stays a plain marker.
            Rectangle {
              id: locSlot
              anchors.verticalCenter: parent.verticalCenter
              readonly property bool isSwitch: rail.selectedIsOrchestrator
              readonly property bool onVm: rail.orchScope === "work"
              readonly property color tint: isSwitch
                ? (Theme.mode === "dark" ? Theme.sky : Theme.electric) : Theme.fg
              readonly property bool expanded: isSwitch && (locHover.hovered || busy)
              property bool busy: false
              onOnVmChanged: busy = false
              height: 22
              // Same padding as the goal pill: 9px inset either side, 22 at rest.
              width: expanded ? locRow.implicitWidth + 18 : 33   // 9 + 15 + 9
              radius: 11
              color: expanded ? Qt.alpha(locSlot.tint, 0.14) : "transparent"
              border.width: 1
              border.color: Qt.alpha(locSlot.tint, expanded ? 0.9 : 0.0)
              // Always present: the header keeps ONE layout in both roster states, so the
              // marker never leaves and the title never has to slide to fill its place.
              // (It used to fade out on collapse, and Row drops invisible children — which
              // is exactly what made the title lag into position.)
              Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
              Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
              Behavior on color { ColorAnimation { duration: 140 } }
              Behavior on border.color { ColorAnimation { duration: 140 } }
              clip: true
              Row {
                id: locRow
                // Same reason as the goal pill: left-anchored so the glyph is a fixed
                // pivot and the label is revealed, never shoved.
                anchors { left: parent.left; leftMargin: 9
                          verticalCenter: parent.verticalCenter }
                spacing: 5
                Spinner {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: locSlot.busy
                  running: locSlot.busy
                  color: locSlot.tint
                }
                Icon {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: !locSlot.busy
                  width: 15; height: 15
                  name: {
                    if (locSlot.isSwitch) return locSlot.onVm ? "cloud--outline--18" : "laptop--outline--18"
                    var arr = rail.liveSessions
                    for (var i = 0; i < arr.length; i++)
                      if (arr[i].name === rail.selectedRaw)
                        return rail._isRemote(arr[i].cwd) ? "cloud--outline--18" : "laptop--outline--18"
                    return "laptop--outline--18"
                  }
                  color: locSlot.tint
                }
                Icon {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: locSlot.expanded && !locSlot.busy
                  width: 13; height: 13
                  name: "toggle-3"
                  color: locSlot.tint
                  transform: Scale { origin.x: 6.5; xScale: locSlot.onVm ? -1 : 1 }
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: locSlot.expanded
                  text: locSlot.busy ? "MOVING" : (locSlot.onVm ? "HERE" : "VM")
                  color: locSlot.tint
                  font { family: Theme.fontFamily; pixelSize: rail.fsMeta - 2; weight: 650 }
                }
              }
              HoverHandler { id: locHover; enabled: locSlot.isSwitch }
              TapHandler {
                enabled: locSlot.isSwitch && !locSlot.busy
                onTapped: {
                  locSlot.busy = true
                  Quickshell.execDetached(["sh", "-c",
                    "notify-send -t 3000 'Orchestrator' 'handover starting…'; " +
                    "out=$($HOME/.local/bin/cockpit-handover 2>&1 | tail -3); " +
                    "notify-send -t 8000 'Orchestrator' \"$out\""])
                }
              }
            }
            Row {
              anchors.verticalCenter: parent.verticalCenter
              spacing: 6
              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: rail.selectedParent.length > 0
                text: rail.shortName(rail.selectedParent).toUpperCase()
                color: Theme.fg_muted
                font { family: Theme.fontFamily; pixelSize: rail.fsMeta; weight: 600 }
              }
              Icon {
                anchors.verticalCenter: parent.verticalCenter
                visible: rail.selectedParent.length > 0
                name: "chevron-right"
                width: 11; height: 11
                color: Theme.fg_muted
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: (rail.shortName(rail.selectedRaw) || "lovable").toUpperCase()
                color: Theme.fg
                font { family: Theme.fontFamily; pixelSize: rail.fsName; bold: true }
              }
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              // A ticket session's plan key IS its name — showing both reads as
              // a stutter (EVERY-3064 EVERY-3064), so the chip only earns its
              // slot when it adds information.
              visible: rail.selectedPlan.length > 0
                && rail.selectedPlan.toUpperCase() !== (rail.shortName(rail.selectedRaw) || "").toUpperCase()
              width: Math.min(implicitWidth, 240)
              elide: Text.ElideMiddle
              text: rail.selectedPlan
              color: Theme.fg_muted
              font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
            }
            // Watchdog visibility: a silently-vanished goal cost hours twice. Armed
            // shows quietly; an orchestrator running WITHOUT a goal is loud.
            // Dot + words, not a glyph — nerd glyphs sit off the text baseline.
            // The "thinking" signifier lives HERE now (the floating pill is gone):
            // same orb grammar as the expanded rows.
            // What it's doing and for how long — the judgment input for
            // Shift+Esc ("this should NOT take 4 minutes").
            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: text.length > 0
              text: rail.runningToolLabel(rail.selectedRaw)
              color: Theme.fg_muted
              font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
            }
          }
          // Right slot: watchdog status beside the location marker (expanded) or
          // the sibling status dots (collapsed) — meta lives right, title left.
          Row {
            anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
            spacing: 12
            // HANDOVER SWITCH — only while the selected session IS the orchestrator, so
            // the control lives with the role rather than floating over a worker's row.
            // The glyph is the state: cloud = the role runs on the dev VM, laptop = here.
            // Click to move it; the direction is derived, so one control works both ways.
            // Sibling dots, then the active session's STATE as the final column. The
            // state column is the rightmost thing in BOTH roster states, so the big orb
            // never moves — collapsing just folds the sibling dots away beside it.
            Item {
              anchors.verticalCenter: parent.verticalCenter
              height: 18
              // dots + gap + the 20px column. The gap carries the orb's 12px overhang
              // ONLY while the orb is drawn; idle it closes to the dots' own 12px rhythm.
              width: (rail.rosterExpanded ? 0
                     : glanceDots.width + (rail.featuredStreaming ? 24 : 12)) + 20
              Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
              Item {
                // One mounted slot crossfades working↔idle without restarting the orb on roster toggles.
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                width: 20; height: 20
                Crossfade {
                  anchors.centerIn: parent
                  width: 44; height: 44
                  showSecond: !rail.featuredStreaming
                  enterDuration: 250
                  exitDuration: 250
                  shift: 0
                  inactiveScale: 0.25
                  first: ThinkingOrb {
                    anchors.fill: parent
                    running: rail.featuredStreaming
                    nodes: 16
                    glow: rail.actionGlow(rail.selectedRaw)
                    seedKey: rail.selectedRaw
                  }
                  second: Rectangle {
                    anchors.centerIn: parent
                    width: 7; height: 7; radius: 3.5
                    color: rail.dotColor(rail.selectedStatus)
                  }
                }
              }
              Row {
              id: glanceDots
              anchors { right: parent.right; verticalCenter: parent.verticalCenter }
              anchors.rightMargin: rail.featuredStreaming ? 44 : 32
              Behavior on anchors.rightMargin {
                NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
              }
              spacing: 12
              opacity: rail.rosterExpanded ? 0 : 1
              Behavior on opacity { NumberAnimation { duration: 220 } }
              Repeater {
              // rosterModel, NOT a filtered array: the array's identity changed on every
              // roster push, so every dot (and running spinner) was destroyed and rebuilt
              // several times a second while anything streamed — the "blinking dots".
              // Rows update in place via setProperty; the selected session's slot hides.
              model: rosterModel
              Item {
                readonly property var md: model.d
                readonly property bool self: (md.rawName || md.name) === rail.selectedRaw
                visible: !self && (md.depth || 0) === 0
                width: 16; height: 16
                Component.onCompleted: rail.probeDotCreates++
              }
              }
            }
            }
          }
        }

        ColumnLayout {
          id: rosterInner
          opacity: rail.rosterExpanded ? 1 : 0
          visible: opacity > 0.01
          property real motionBlur: rail.rosterExpanded ? 0 : 0.125
          property real motionY: rail.rosterExpanded ? 0 : -4
          transform: Translate { y: rosterInner.motionY }
          layer.enabled: rosterFade.running || rosterBlur.running || rosterShift.running
          layer.effect: MultiEffect { blurEnabled: true; blurMax: 16; blur: rosterInner.motionBlur }
          Behavior on opacity { NumberAnimation { id: rosterFade; duration: Motion.slow; easing.type: Easing.InOutQuad } }
          Behavior on motionBlur { NumberAnimation { id: rosterBlur; duration: Motion.slow; easing.type: Easing.InOutQuad } }
          Behavior on motionY { NumberAnimation { id: rosterShift; duration: Motion.slow; easing.type: Easing.OutCubic } }
          anchors { left: parent.left; right: parent.right; top: glanceCol.bottom; topMargin: 4 }
          spacing: 3
          Repeater {
            model: rosterModel
            Rectangle {
              id: sessRow
              // Republish the row's data under the name the delegate already uses, so the
              // switch from an array model to a ListModel touches one line, not thirty.
              readonly property var modelData: model.d
              Layout.fillWidth: true
              implicitHeight: 40
              radius: height / 2   // pill rows (as before)
              // `!rail.insert` matters: the cursor fill means "keyboard is here", so
              // it must clear while the composer owns input (the feed + files
              // delegates already guard this way).
              readonly property bool cursor: rail.focused && !rail.insert && rail.cur === index
              readonly property bool selected: (modelData.rawName || modelData.name) === rail.selectedRaw
              readonly property bool streaming: modelData.status === "streaming"
            readonly property bool hasAsk: {
              rail.agentd ? rail.agentd.askGen : 0
              return rail.agentd ? rail.agentd.askFor(modelData.rawName || modelData.name) !== null : false
            }
              // The theme's surface ladder, so cursor vs selected stay two clear
              // steps apart in both modes: hover < selected (surface1) <
              // cursor (selection). fg-alpha washes collapsed into one grey.
              color: cursor ? Theme.selection
                   : selected ? Theme.surface1
                   : hov.hovered ? Theme.surface : "transparent"
              HoverHandler { id: hov }
              // Collapsed: index doesn't map to the full list → just focus/expand.
              TapHandler { onTapped: rail.rosterExpanded ? rail.clickAt(index) : rail.requestFocus() }
              RowLayout {
                anchors { fill: parent; leftMargin: 14 + (modelData.depth || 0) * 20; rightMargin: 14 }
                spacing: 8
                // Nesting connector for spawned subagents.
                Text {
                  visible: (modelData.depth || 0) > 0
                  text: "↳"; color: Theme.fg_muted
                  font.family: Theme.fontFamily; font.pixelSize: rail.fsName
                  Layout.alignment: Qt.AlignVCenter
                }
                // Where the agent actually runs: cloud = a lovbox worktree, laptop =
                // this machine. Same ink as the name it sits next to.
                Icon {
                  // Outline cuts, and both from the 18px set so their stroke weights match —
                  // there is no laptop--outline--12. Drawn at 14 rather than 13 to give the
                  // laptop's outline enough room to read as a laptop and not a rectangle.
                  name: modelData.remote ? "cloud--outline--18" : "laptop--outline--18"
                  width: 14; height: 14
                  Layout.preferredWidth: 14; Layout.preferredHeight: 14
                  Layout.alignment: Qt.AlignVCenter
                  color: Theme.fg
                }
                Text {
                  text: modelData.name
                  // Content-sized, so the spinner hugs the name's right edge instead of being
                  // pushed to the row's edge. The cap comes from the ROW, never from this
                  // item's own implicitWidth: capping a text by its own width — which is then
                  // what elide reacts to — is self-referential and settles arbitrarily (it ate
                  // the last glyph of the SHORT name while longer ones were fine). 190 is the
                  // rest of the row: margins 28 + icon 14 + orb 16 + status 74 + devenv 15 +
                  // five 8px gaps.
                  Layout.fillWidth: false
                  // The role badge eats from the NAME's budget, never from the orb/status
                  // slots to its right — a long ticket name with a badge otherwise squeezed
                  // the working orb.
                  Layout.maximumWidth: Math.max(48, sessRow.width - 190 - (modelData.depth || 0) * 20
                                                - (roleBadge.visible ? roleBadge.width + 8 : 0))
                  elide: Text.ElideRight
                  color: Theme.fg
                  font.family: Theme.fontFamily; font.pixelSize: rail.fsName
                  // Bold marks SELECTION only. Streaming has the orb, and bolding for it too
                  // meant two rows shouting at once with no way to tell which you were on.
                  font.weight: sessRow.selected ? 600 : 400
                }
                // Role badge (agentd profiles): orchestrator / worker / reviewer / watcher.
                // The daemon reports "profile" like "lovable-orchestrator" — show the last
                // segment, muted, so identity reads without shouting over the name.
                CapLabel {
                  id: roleBadge
                  visible: text.length > 0
                  text: {
                    var p = String(sessRow.modelData.profile || sessRow.modelData.role || "")
                    if (!p.length) return ""
                    var seg = p.split("-")
                    return seg[seg.length - 1]
                  }
                  color: Theme.fg_muted
                }
                // Spinner immediately right of the name. The slot is reserved even when idle
                // so nothing shifts as a session starts or stops working. 20px is free (the
                // row is a fixed 40px tall) and 20 is what it takes to LOOK bigger: the box
                // draws a sphere ~0.83 of its size, so a 16px box was only ~13px of visible
                // mesh next to 14px icons.
                Item { Layout.fillWidth: true }   // state lives on the right edge
                // needs-input beacon: the one roster state that outranks everything.
                Rectangle {
                  visible: sessRow.hasAsk
                  implicitWidth: askCap.implicitWidth + 14
                  implicitHeight: 20; radius: 10
                  color: Theme.orange
                  Layout.alignment: Qt.AlignVCenter
                  Text {
                    id: askCap; anchors.centerIn: parent
                    text: "needs input"
                    color: Theme.bg; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2; font.bold: true
                  }
                }
                // Tool + elapsed while streaming: the only status WORDS left, and only
                // when there is something to say. idle/asleep are the dot's job now.
                Text {
                  text: {
                    rail.nowTick
                    rail.agentd ? rail.agentd.curToolGen : 0
                    if (sessRow.hasAsk || !sessRow.streaming) return ""
                    var sid2 = modelData.rawName || modelData.name
                    if (rail.agentd && rail.agentd.curToolLiveFor(sid2)) {
                      var secs = Math.max(0, Math.round((Date.now() - rail.agentd.curToolAtFor(sid2)) / 1000))
                      var el = secs >= 60 ? Math.floor(secs / 60) + "m" + String(secs % 60).padStart(2, "0") : secs + "s"
                      return (rail.agentd.curToolFor(sid2) || "tool") + " · " + el
                    }
                    return ""
                  }
                  // Fade, never blink: the label appears the moment a tool starts and goes
                  // the moment it ends, and toggling `visible` made every tool boundary a
                  // flash. Opacity crossfades instead, and the item keeps its slot so the
                  // row never reflows as the text comes and goes.
                  opacity: text.length > 0 ? 1 : 0
                  Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                  horizontalAlignment: Text.AlignRight
                  Layout.alignment: Qt.AlignVCenter
                  // Breathing room before the state slot: "bash-write · 2s" sat flush
                  // against the orb and read as one glued token. 18 clears the orb's 12px
                  // overhang past its column with a real gap left over.
                  Layout.rightMargin: 18
                  color: Theme.fg_muted
                  font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
                }
                // Connection trouble is the only thing that earns an icon here: a worker
                // whose daemon went away. Red, left of the state slot, absent otherwise —
                // the green devenv plug that used to live on the right was decoration and
                // pushed the dots off the edge.
                Icon {
                  visible: modelData.offline === true || modelData.status === "offline"
                  name: "bolt-slash"
                  width: 14; height: 14
                  Layout.preferredWidth: visible ? 14 : 0
                  Layout.preferredHeight: 14
                  Layout.alignment: Qt.AlignVCenter
                  color: Theme.red
                }
                // ONE state slot at the right edge, same vocabulary as the collapsed dots:
                // orb = working, muted dot = resting, pulsing orange =
                // needs input. The slot is always reserved so nothing shifts on a change.
                Item {
                  Layout.preferredWidth: 20; Layout.preferredHeight: 20
                  Layout.alignment: Qt.AlignVCenter
                  ThinkingOrb {
                    anchors.fill: parent
                    visible: sessRow.streaming && !sessRow.hasAsk && (modelData.depth || 0) > 0
                    running: visible
                    nodes: 13
                    glow: rail.actionGlow(modelData.rawName || modelData.name)
                    seedKey: modelData.rawName || modelData.name
                    invertRing: false
                  }
                  Rectangle {
                    anchors.centerIn: parent
                    visible: !sessRow.streaming && !sessRow.hasAsk && (modelData.depth || 0) > 0
                    width: 7; height: 7; radius: 3.5
                    color: rail.dotColor(modelData.status || modelData.state || "")
                  }
                  Rectangle {
                    anchors.centerIn: parent
                    visible: sessRow.hasAsk && (modelData.depth || 0) > 0
                    width: 9; height: 9; radius: 4.5; color: Theme.orange
                    SequentialAnimation on opacity {
                      running: visible; loops: Animation.Infinite
                      NumberAnimation { to: 0.35; duration: 600; easing.type: Easing.InOutQuad }
                      NumberAnimation { to: 1.0;  duration: 600; easing.type: Easing.InOutQuad }
                    }
                  }
                }
              }
            }
          }
        }

        // Root-session markers stay mounted while moving between the collapsed
        // glance and expanded row, preserving orb shader phase exactly.
        Repeater {
          model: rosterModel
          Item {
            id: sharedRosterOrb
            readonly property var md: model.d
            readonly property bool rootSession: (md.depth || 0) === 0
            readonly property bool hasAsk: {
              rail.agentd ? rail.agentd.askGen : 0
              return rail.agentd ? rail.agentd.askFor(md.rawName || md.name) !== null : false
            }
            width: rail.rosterExpanded ? 20 : 16
            height: width
            x: rail.rosterExpanded ? rosterCard.width - 34 : rosterCard.collapsedOrbX(index) - 14
            y: rail.rosterExpanded ? rosterInner.y + index * 43 + 10 : glanceCol.y + 18
            visible: rootSession
            z: 5

            Behavior on x { NumberAnimation { duration: Motion.base; easing.type: Easing.InOutQuad } }
            Behavior on y { NumberAnimation { duration: Motion.base; easing.type: Easing.InOutQuad } }
            Behavior on width { NumberAnimation { duration: Motion.base; easing.type: Easing.InOutQuad } }

            ThinkingOrb {
              anchors.fill: parent
              visible: !sharedRosterOrb.hasAsk && sharedRosterOrb.md.status === "streaming"
              running: visible
              glow: rail.actionGlow(sharedRosterOrb.md.rawName || sharedRosterOrb.md.name)
              seedKey: sharedRosterOrb.md.rawName || sharedRosterOrb.md.name
            }
            Rectangle {
              anchors.centerIn: parent
              visible: !sharedRosterOrb.hasAsk && sharedRosterOrb.md.status !== "streaming"
              width: 7; height: 7; radius: 3.5
              color: rail.dotColor(sharedRosterOrb.md.status || sharedRosterOrb.md.state || "")
            }
            Rectangle {
              anchors.centerIn: parent
              visible: sharedRosterOrb.hasAsk
              width: 9; height: 9; radius: 4.5; color: Theme.orange
              SequentialAnimation on opacity {
                running: visible; loops: Animation.Infinite
                NumberAnimation { to: 0.35; duration: 600; easing.type: Easing.InOutQuad }
                NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutQuad }
              }
            }
          }
        }
      }

      // Queued-message pill: Ctrl+Enter holds a message for the turn's end; without a
      // visible trace it reads as "my message vanished".
      Rectangle {
        visible: rail.agentd && rail.agentd.queuedGen >= 0 && rail.agentd.queuedFor(rail.selectedRaw) > 0
        Layout.fillWidth: true
        implicitHeight: 26
        radius: 6
        color: Theme.surface0
        border.width: 1; border.color: Theme.hairline
        RowLayout {
          anchors { left: parent.left; right: parent.right; leftMargin: 10; rightMargin: 10
                    verticalCenter: parent.verticalCenter }
          spacing: 8
          Icon {
            name: "alarm-clock--outline--18"
            width: 13; height: 13; color: Theme.fg_muted
            Layout.preferredWidth: 13; Layout.preferredHeight: 13
            Layout.alignment: Qt.AlignVCenter
          }
          Text {
            Layout.fillWidth: true
            // queuedGen is the invalidation signal: `queued` is mutated in place, so
            // without touching the gen these bindings froze at their first value
            // (the pill appeared but said "0 queued: ''").
            readonly property int qn: {
              rail.agentd ? rail.agentd.queuedGen : 0
              return rail.agentd ? rail.agentd.queuedFor(rail.selectedRaw) : 0
            }
            text: {
              rail.agentd ? rail.agentd.queuedGen : 0
              return qn + " queued — sends when the turn ends: “"
                  + (rail.agentd ? rail.agentd.queuedFirst(rail.selectedRaw) : "").slice(0, 60) + "”"
            }
            color: Theme.fg_muted
            font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
            elide: Text.ElideRight
          }
        }
      }


    // A turn that stopped on a question. Deliberately NOT the ask card: it is not
    // answerable, so it states what happened and gets out of the way (Ctrl+d dismisses).
    Rectangle {
      visible: rail.staleAsk !== null && !rail.pendingAsk && rail.view === "chat"
      Layout.fillWidth: true
      implicitHeight: staleCol.implicitHeight + 20
      radius: 12
      color: Theme.surface
      border.width: 1
      border.color: Theme.hairline
      z: 11

      ColumnLayout {
        id: staleCol
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter
                  leftMargin: 14; rightMargin: 14 }
        spacing: 3
        RowLayout {
          spacing: 6
          Icon {
            name: "clock"
            width: 13; height: 13
            Layout.preferredWidth: 13; Layout.preferredHeight: 13
            Layout.alignment: Qt.AlignVCenter
            color: Theme.fg_muted
          }
          Text {
            Layout.fillWidth: true
            text: "stopped on a question — send a prompt with your answer to continue"
            color: Theme.fg_muted
            font.pixelSize: rail.fsMeta
            font.family: Theme.fontFamily
            elide: Text.ElideRight
          }
          KeyCap { small: true; text: "C-d" }
          CapLabel { text: "dismiss" }
        }
        Text {
          Layout.fillWidth: true
          text: rail.staleAsk ? rail.staleAsk.title : ""
          color: Theme.fg
          font.pixelSize: rail.fsBody
          font.family: Theme.fontFamily
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }
      }
    }

    // ask_user card — mirrors the nvim rail's "needs your input" approval: a
    // bordered card that TAKES OVER the composer's slot — same bottom edge as the input,
    // growing upward as it gets taller. confirm → y/n; select → 1–9;
    // input/editor → i to type. Answered via the rail's Keys / the composer.
    Rectangle {
      id: askCard
      readonly property var ask: rail.pendingAsk
      readonly property var userBash: rail.pendingUserBash
      readonly property string prompt: ask ? String(ask.message || ask.placeholder || "") : ""
      visible: ask !== null && rail.view === "chat"
      Layout.fillWidth: true
      implicitHeight: askCol.implicitHeight + 28
      radius: 14
      color: Theme.surface
      border.width: 1
      border.color: Theme.orange
      z: 12

      Rectangle {   // left attention accent
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom; topMargin: 12; bottomMargin: 12 }
        width: 2; radius: 1; color: Theme.orange
      }

      Column {
        id: askCol
        anchors { left: parent.left; right: parent.right; top: parent.top
                  leftMargin: 18; rightMargin: 16; topMargin: 14 }
        spacing: 9

        Text {
          text: askCard.userBash ? "run as you" : "needs your input"
          color: Theme.orange; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta; font.bold: true
        }
        Text {
          visible: text.length > 0; width: parent.width; wrapMode: Text.Wrap
          text: askCard.userBash ? ("! " + String(askCard.userBash.command || ""))
                                 : (askCard.ask ? (askCard.ask.title || "") : "")
          color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
        }
        Text {
          visible: text.length > 0; width: parent.width; wrapMode: Text.Wrap
          text: askCard.userBash
              ? (String(askCard.userBash.reason || "") + "\n" + String(askCard.userBash.host || "") + ":" + String(askCard.userBash.cwd || ""))
              : rail.colorizeLinks(askCard.prompt)
          textFormat: askCard.userBash ? Text.PlainText : Text.MarkdownText
          color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
          onLinkActivated: (url) => Quickshell.execDetached(["xdg-open", url])
        }
        // An ask with NO title and NO message is unanswerable as posed — say so
        // instead of presenting a bare box (the payload is journaled by agentd).
        Text {
          visible: askCard.ask && !askCard.userBash
                   && !String(askCard.ask.title || "").length
                   && !askCard.prompt.length
          width: parent.width; wrapMode: Text.Wrap
          text: "the agent asked for input without saying why — press t to make it explain, or esc to cancel the question"
          color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
          font.italic: true
        }

        // select → one keycap-numbered row per option
        Column {
          spacing: 6
          visible: askCard.ask && askCard.ask.method === "select"
          Repeater {
            model: (askCard.ask && askCard.ask.method === "select") ? askCard.ask.options : []
            Row {
              spacing: 9
              KeyCap { text: String(index + 1); anchors.verticalCenter: parent.verticalCenter }
              Text {
                text: modelData; color: Theme.fg; width: askCol.width - 40; wrapMode: Text.Wrap
                font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }
        }

        // confirm → y / n
        Row {
          spacing: 20
          visible: askCard.ask && askCard.ask.method === "confirm"
          Row { spacing: 8; KeyCap { text: "y"; anchors.verticalCenter: parent.verticalCenter }
            Text { text: askCard.userBash ? "Run" : "yes"; color: Theme.green; font.family: Theme.fontFamily; font.pixelSize: rail.fsBody; anchors.verticalCenter: parent.verticalCenter }
            TapHandler { onTapped: rail.answerAsk({ confirmed: true }) } }
          Row { spacing: 8; KeyCap { text: "n"; anchors.verticalCenter: parent.verticalCenter }
            Text { text: askCard.userBash ? "Decline" : "no"; color: Theme.red; font.family: Theme.fontFamily; font.pixelSize: rail.fsBody; anchors.verticalCenter: parent.verticalCenter }
            TapHandler { onTapped: rail.answerAsk({ confirmed: false }) } }
          // Neither yes nor no: release the agent from the question and open the composer,
          // for the common case where the question itself is the thing worth discussing.
          Row { visible: !askCard.userBash; spacing: 8; KeyCap { text: "t"; anchors.verticalCenter: parent.verticalCenter }
            Text { text: "talk about this"; color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: rail.fsBody; anchors.verticalCenter: parent.verticalCenter } }
        }

        // input/editor → answer HERE, in the card, not in the composer below
        Rectangle {
          width: askCol.width
          visible: askCard.ask && (askCard.ask.method === "input" || askCard.ask.method === "editor")
          implicitHeight: 44
          height: implicitHeight
          radius: 10
          color: Theme.surface0
          border.color: rail.insert ? Theme.orange : Theme.hairline
          border.width: 1
          RowLayout {
            anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
            spacing: 8
            Icon { name: "chevron-right"; width: 14; height: 14; color: Theme.orange }
            TextInput {
              id: askInput
              Layout.fillWidth: true
              color: Theme.fg
              font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
              clip: true
              verticalAlignment: TextInput.AlignVCenter
              cursorDelegate: Rectangle { width: 2; radius: 1; color: Theme.cursor; opacity: askInput.cursorVisible ? 1 : 0 }
              onAccepted: {
                if (text.trim().length) rail.answerAsk({ value: text })
                text = ""
                rail.exitInsert()
              }
              Keys.onPressed: (e) => {
                if (e.key === Qt.Key_Escape) { rail.exitInsert(); e.accepted = true }
              }
            }
            Text {
              visible: !rail.insert
              text: "i to answer"
              color: Theme.fg_muted
              font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
            }
          }
        }

        Text {
          readonly property bool hasUrl: askCard.ask && rail.firstUrl(String(askCard.ask.title || "") + "\n" + askCard.prompt).length > 0
          text: (hasUrl ? "ctrl+o opens link · " : "") + (rail.askDeferred ? "finish typing · esc to answer"
              : askCard.userBash ? "click Run · y runs · n declines · esc cancels"
              : (askCard.ask && askCard.ask.method === "select")
                ? "press a number · t to talk · esc cancels" : "t to talk · esc cancels")
          color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
        }
      }
    }

      // new-session panel — same shape as an ask card, because it is one: it takes over
      // the chin, and the composer hides beneath it.
      Rectangle {
        id: newCard
        Layout.fillWidth: true
        visible: rail.newOpen
        implicitHeight: newCol.implicitHeight + 24
        radius: 14
        color: Theme.surface
        border.width: 1
        border.color: Theme.electric
        Column {
          id: newCol
          anchors { left: parent.left; right: parent.right; top: parent.top
                    leftMargin: 18; rightMargin: 16; topMargin: 12 }
          spacing: 8
          Text {
            text: rail.newMode === "plan-new" ? "new plan — describe the task"
                : rail.newSpawnPending && rail.newSpawnPending.rebind ? ("bind plan · " + rail.shortName(rail.newSpawnPending.session))
                : rail.newSpawnPending ? ("new session · " + rail.newFolder.split("/").pop() + " — do you have a plan?")
                : rail.newFolder.length ? ("new session · " + rail.newFolder.split("/").pop()) : "new session — pick a folder"
            color: Theme.electric
            font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta; font.bold: true
          }
          // Pane 1 — folders (recent-first, fuzzy-filtered by typing).
          Text {
            visible: rail.newMode !== "remote" && rail.newMode !== "plan-new" && (!rail.newFolder.length || !!rail.newSpawnPending) && rail.newFilter.length > 0
            text: "filter: " + rail.newFilter
            color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
          }
          Column {
            width: newCol.width
            visible: rail.newMode !== "remote" && !rail.newFolder.length
            spacing: 2
            Repeater {
              model: rail.newFolderRows.slice(rail.newWinStart, rail.newWinStart + 12)
              Rectangle {
                width: parent.width; implicitHeight: 30; radius: 8
                color: (rail.newWinStart + index) === rail.newCur ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.10) : "transparent"
                Row {
                  anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                  spacing: 8
                  Text { text: modelData.name; color: Theme.fg
                         font.family: Theme.fontFamily; font.pixelSize: rail.fsBody }
                  Text {
                    // how many sessions already live there — the resume signal
                    text: { rail.agentd ? rail.agentd.sessions.length : 0
                            var c = rail.sessionsIn(modelData.path).length
                            return c > 0 ? c + " session" + (c > 1 ? "s" : "") : "" }
                    color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
                TapHandler { onTapped: rail.pickFolder(modelData.path) }
              }
            }
          }
          // Pane 2 — resume an existing session or start new in the folder.
          Column {
            width: newCol.width
            visible: rail.newMode !== "remote" && rail.newFolder.length > 0 && !rail.newSpawnPending
            spacing: 2
            Repeater {
              model: rail.newWhichRows
              Rectangle {
                width: parent.width; implicitHeight: 30; radius: 8
                color: index === rail.newCur ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.10) : "transparent"
                Row {
                  anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                  spacing: 8
                  Text {
                    text: modelData.kind === "new"   ? "+ new session (" + rail.newSessionName(rail.newFolder) + ")"
                        : modelData.kind === "adopt" ? "adopt orphaned transcript · " + (modelData.stamp || modelData.id.slice(0, 19))
                        : (modelData.sess.name + "  ·  " + (modelData.sess.status || "?"))
                    color: modelData.kind === "new" ? Theme.electric
                         : modelData.kind === "adopt" ? Theme.fg_muted : Theme.fg
                    font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
                  }
                }
                TapHandler { onTapped: { rail.newCur = index; rail.activateWhich(modelData) } }
              }
            }
          }
          // Pane 3 — bind a vault plan (or none) before the spawn goes out.
          Column {
            width: newCol.width
            visible: !!rail.newSpawnPending && rail.newMode !== "plan-new"
            spacing: 2
            Repeater {
              model: rail.newPlanRows.slice(rail.newPlanWinStart, rail.newPlanWinStart + 12)
              Rectangle {
                width: parent.width; implicitHeight: 30; radius: 8
                color: (rail.newPlanWinStart + index) === rail.newCur ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.10) : "transparent"
                Row {
                  anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                  spacing: 8
                  Text {
                    text: modelData.newPlan ? "new plan…"
                        : modelData.none ? "no plan" : modelData.slug
                    color: modelData.none ? Theme.fg_muted
                         : modelData.newPlan ? Theme.electric : Theme.fg
                    font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
                  }
                }
                TapHandler { onTapped: { rail.newCur = rail.newPlanWinStart + index; rail.activatePlan(modelData) } }
              }
            }
          }
          Rectangle {
            width: newCol.width
            visible: rail.newMode === "remote" || rail.newMode === "plan-new"
            implicitHeight: 44; height: implicitHeight
            radius: 10
            color: Theme.surface0
            border.color: rail.insert ? rail.activeRing : Theme.hairline
            border.width: 2
            Behavior on border.color { ColorAnimation { duration: 650; easing.type: Easing.InOutQuad } }
            RowLayout {
              anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
              spacing: 8
              Icon {
                name: "chevron-right"; width: 14; height: 14
                color: rail.insert ? rail.activeRing : Theme.hairline
                Behavior on color { ColorAnimation { duration: 650; easing.type: Easing.InOutQuad } }
              }
              TextInput {
                id: newInput
                Layout.fillWidth: true
                color: Theme.fg
                font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
                clip: true
                verticalAlignment: TextInput.AlignVCenter
                cursorDelegate: Rectangle { width: 2; radius: 1; color: Theme.cursor; opacity: newInput.cursorVisible ? 1 : 0 }
                onAccepted: {
                  if (rail.newMode === "plan-new") rail.submitPlanDescription(text)
                  else rail.createSession(text)
                  text = ""
                }
                Keys.onPressed: (e) => {
                  if (e.key === Qt.Key_Escape) { rail.closeNew(); e.accepted = true }
                }
              }
            }
          }
          Text {
            text: rail.newMode === "remote" ? "ticket id, e.g. EVERY-2739 · esc cancels"
                : rail.newMode === "plan-new" ? "enter dispatches /plan-ticket · esc cancels"
                : rail.newSpawnPending      ? "type to filter plans · j/k + enter binds · esc back"
                : rail.newFolder.length     ? "j/k + enter — resume or start new · esc back"
                : "type a name or ~/path · zoxide matches · ↑/↓ picks · tab completes · enter opens" + (rail.remoteOffered ? " · r = remote VM" : "") + " · esc cancels"
            color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
          }
        }
      }

      // Composer — real text input (i to enter, Esc/Ctrl+h to leave). Hidden while an
      // ask is pending: the question TAKES OVER the input rather than floating above a
      // composer that still looks ready for an unrelated message.
      Rectangle {
        Layout.fillWidth: true
        visible: (!rail.pendingAsk || rail.askDeferred) && !rail.newOpen
        // Grows with the text up to ~3 lines (slqs Composer pattern); beyond that the
        // Flickable scrolls the caret into view.
        implicitHeight: Math.max(52, Math.min(composerInput.implicitHeight + 30, 94))
        radius: Math.min(height / 2, 26)   // pill at one line, rounded card when grown
        color: Theme.bg
        border.color: rail.insert ? rail.activeRing : Theme.hairline
        border.width: 2
        Behavior on border.color { ColorAnimation { duration: 650; easing.type: Easing.InOutQuad } }
        RowLayout {
          anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
          spacing: 8
          Icon {
            name: "chevron-right"; width: 14; height: 14
            // Rides the outline exactly (same hue, same glide) so prompt + frame
            // read as one piece of chrome.
            color: rail.insert ? rail.activeRing : Theme.hairline
            Behavior on color { ColorAnimation { duration: 650; easing.type: Easing.InOutQuad } }
            // Centered on the FIRST text line, derived from the real line height
            // (cursorRectangle) instead of a hand-tuned constant — the guess drifted
            // off-center the moment the TextArea's metrics differed from TextInput's.
            Layout.alignment: Qt.AlignTop
            Layout.topMargin: composerFlick.Layout.topMargin + Math.max(0, (composerInput.cursorRectangle.height - height) / 2)
          }
          Flickable {
            id: composerFlick
            Layout.fillWidth: true; Layout.fillHeight: true
            Layout.topMargin: 15; Layout.bottomMargin: 15
            contentHeight: composerInput.implicitHeight; clip: true
            boundsBehavior: Flickable.StopAtBounds
            // keep the caret in view once the text grows past the 3-line cap
            function ensureVisible(r) {
              if (contentY >= r.y) contentY = r.y
              else if (contentY + height <= r.y + r.height) contentY = r.y + r.height - height
            }
          TextArea {
            id: composerInput
            width: composerFlick.width
            padding: 0
            background: null
            wrapMode: TextArea.Wrap
            color: Theme.fg
            font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
            onCursorRectangleChanged: composerFlick.ensureVisible(cursorRectangle)
            // Orange blinking caret, matching the sibling apps (Theme.cursor).
            cursorDelegate: Rectangle { width: 2; radius: 1; color: Theme.cursor; opacity: composerInput.cursorVisible ? 1 : 0 }
            // TextArea has no onAccepted — plain Enter routes here from Keys below.
            // Shift+Enter falls through to the default handler = a newline.
            function sendNow() {
              if (rail.askDeferred) return
              var pa = rail.pendingAsk
              // /goal — rail-intercepted (never reaches pi): pins a watchdog goal
              // on the selected session; "/goal done" or bare "/goal" clears it.
              // /handover — rail-intercepted: move the orchestrator role to the
              // VM (default) or back ("local"/"back"/"home"). Runs the script
              // detached; progress is visible in the orchestrator's own feed
              // (it authors its handoff as a normal turn).
              var hm2 = text.match(/^\/handover\s*(\S*)\s*$/)
              if (hm2) {
                var dir = /^(local|back|home)$/i.test(hm2[1]) ? "local" : "vm"
                Quickshell.execDetached(["bash", "-c",
                  "cockpit-handover " + dir + " >> \"$HOME/.local/state/cockpit/handover.log\" 2>&1"])
                if (rail.agentd) rail.agentd._setTransient(rail.selectedRaw, "handover", "info",
                  "↳ handover → " + dir + " started — the orchestrator writes its handoff first (~minutes); log: ~/.local/state/cockpit/handover.log", 120000)
                text = ""
                composerInput.forceActiveFocus()
                return
              }
              var gm = text.match(/^\/goal\s*([\s\S]*)$/)
              if (gm) {
                var g = gm[1].trim()
                if (/^(done|clear)$/i.test(g)) g = ""
                if (rail.agentd) rail.agentd.send({ type: "set_goal", session: rail.selectedRaw, goal: g })
                text = ""
                composerInput.forceActiveFocus()
                return
              }
              if (pa && (pa.method === "input" || pa.method === "editor")) {
                if (text.trim().length) rail.answerAsk({ value: text })
              } else if (rail.agentd && !rail.attachRefs(text).trim().length && !rail.featuredStreaming
                         && rail.agentd.myAbortAgoFor(rail.selectedRaw) >= 0
                         && rail.agentd.myAbortAgoFor(rail.selectedRaw) < 1800000) {
                // Empty Enter after an interrupt = RESUME: pick the turn back up
                // without typing the ritual "continue" by hand.
                rail.agentd.submit(rail.selectedRaw, "Continue where you left off.")
                rail.rosterOverride = false
              } else if (rail.agentd && rail.attachRefs(text).trim().length) {
                // Judge the OUTGOING message: a pasted-then-token-deleted image must
                // not fire a blank prompt just because pastedImages is non-empty.
                rail.agentd.submit(rail.selectedRaw, rail.attachRefs(text))
                rail.rosterOverride = false   // sending = focus the conversation; roster compacts
              }
              rail.pastedImages = []      // attachments belong to the message just sent
              // No settle burst on a send: the rows are already sized, so re-pinning
              // 9x over ~540ms was visible as a flicker on the first message.
              feedScroll.toEnd()
              // Stay in insert after sending — you almost always have a follow-up,
              // and dropping to normal mode meant pressing `i` again every time.
              // Esc / Ctrl+h still leave. (An answered ask_user is done, so exit.)
              text = ""
              if (pa && (pa.method === "input" || pa.method === "editor")) rail.exitInsert()
              else composerInput.forceActiveFocus()
            }
            Keys.onPressed: (e) => {
              var ctrl = (e.modifiers & Qt.ControlModifier)
              // The old TextInput let C-d bubble to the rail's stale-notice dismiss;
              // the Controls TextArea consumes it, so handle it here explicitly.
              if (ctrl && e.key === Qt.Key_D && rail.staleAsk) {
                rail.dismissStaleAsk(); e.accepted = true; return
              }
              // Plain Enter sends (the TextInput's onAccepted, relocated); Shift+Enter
              // is left to the default handler and inserts a newline.
              if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && !ctrl && !(e.modifiers & Qt.ShiftModifier)) {
                // Slash palette: Enter on a partial command completes instead (below).
                if (!(rail.slashOpen && rail.composerText.slice(1) !== rail.commandMatches[rail.slashCur])) {
                  composerInput.sendNow(); e.accepted = true; return
                }
              }
              // Esc while the agent runs = interrupt it (Claude Code's Esc), keeping
              // insert — you are about to type what it should do instead. Idle: the
              // usual leave-insert.
              if (e.key === Qt.Key_Escape) {
                if (rail.askDeferred) {
                  rail.askDeferred = false
                  if (rail.askWantsText) Qt.callLater(rail.enterInsert)
                  else rail.exitInsert()
                } else if (rail.featuredStreaming && rail.agentd && rail.selectedRaw) rail.agentd.interrupt(rail.selectedRaw)
                else rail.exitInsert()
                e.accepted = true; return
              }
              // Ctrl+Enter = QUEUE: hold the message until the turn ends (or is
              // aborted), then send it as a fresh prompt. Plain Enter steers the live
              // turn instead — see onAccepted / submit().
              if (ctrl && (e.key === Qt.Key_Return || e.key === Qt.Key_Enter)) {
                if (rail.agentd && rail.selectedRaw && rail.attachRefs(text).trim().length) {
                  rail.agentd.enqueue(rail.selectedRaw, rail.attachRefs(text))
                  rail.rosterOverride = false
                  rail.pastedImages = []
                  text = ""
                }
                e.accepted = true; return
              }
              // Ctrl+V: the clipboard may hold an IMAGE, and we only learn that
              // asynchronously (wl-paste --list-types), so swallow the key and let
              // pasteImage() decide — it falls back to a text paste when there is no
              // image, so one path covers both.
              if (ctrl && e.key === Qt.Key_V && !(e.modifiers & Qt.ShiftModifier)) {
                rail.pasteImage(); e.accepted = true; return
              }
              // Slash palette owns Tab / ↑↓ / Ctrl+n,p while it's open.
              if (rail.slashOpen) {
                var n = rail.commandMatches.length
                if (e.key === Qt.Key_Tab) { rail.acceptSlash(); e.accepted = true; return }
                if (e.key === Qt.Key_Down || (ctrl && e.key === Qt.Key_N)) { rail.slashCur = (rail.slashCur + 1) % n; e.accepted = true; return }
                if (e.key === Qt.Key_Up   || (ctrl && e.key === Qt.Key_P)) { rail.slashCur = (rail.slashCur - 1 + n) % n; e.accepted = true; return }
                // Enter on a partial command completes it instead of sending.
                if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter)
                    && rail.composerText.slice(1) !== rail.commandMatches[rail.slashCur]) {
                  rail.acceptSlash(); e.accepted = true; return
                }
              }
              if (e.key === Qt.Key_Escape) { rail.exitInsert(); e.accepted = true }
              // No exitInsert here: clearing insert BEFORE the blur meant the
              // focus handler recorded "wasn't typing" and returns landed in the
              // chat. Leave insert set; the blur captures it and re-enters on return.
              else if (ctrl && e.key === Qt.Key_H) { rail.focusNvim(); e.accepted = true }
              else if (ctrl && e.key === Qt.Key_K) {
                rail.view = "chat"
                rail.exitInsert()
                rail.cur = Math.max(0, rail.navTotal - 1)
                e.accepted = true
              }
            }
            Text {
              anchors.fill: parent
              verticalAlignment: Text.AlignVCenter
              visible: !composerInput.text && !composerInput.activeFocus
              text: (rail.pendingAsk && (rail.pendingAsk.method === "input" || rail.pendingAsk.method === "editor"))
                    ? "type your reply…   (⏎ to send · esc cancels)"
                    : "message " + rail.featured.name + "…"
              color: Theme.fg_muted; font: composerInput.font
            }
          }
          }
        }
      }

      // Keybind hints (QsLib KeyCap/CapLabel) — the chin is the ONE place bindings are
      // documented, and it follows the state you are actually in: insert shows the
      // send/steer/queue grammar (which used to be crammed into the placeholder), an ask
      // shows its answer keys, and normal mode differs between a roster and a feed cursor.
      RowLayout {
        Layout.fillWidth: true
        transform: Translate { y: 6 }
        spacing: 6

        Rectangle {
          id: scopeSwitch
          Layout.alignment: Qt.AlignVCenter
          Layout.rightMargin: -4
          readonly property color tint: rail.scopeMode === "work" ? Theme.electric : Theme.orange
          readonly property bool expanded: scopeHover.hovered
          implicitWidth: expanded ? scopeRow.implicitWidth + 12 : 30
          implicitHeight: 22
          radius: 11
          color: expanded ? Qt.alpha(scopeSwitch.tint, 0.14) : "transparent"
          border.width: 1
          border.color: Qt.alpha(scopeSwitch.tint, expanded ? 0.9 : 0.0)
          Behavior on implicitWidth { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
          Behavior on color { ColorAnimation { duration: 140 } }
          Behavior on border.color { ColorAnimation { duration: 140 } }
          clip: true
          Row {
            id: scopeRow
            anchors { left: parent.left; leftMargin: 6; verticalCenter: parent.verticalCenter }
            spacing: 5
            Icon {
              anchors.verticalCenter: parent.verticalCenter
              width: 18; height: 18
              name: "toggle-3"
              color: scopeSwitch.tint
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: scopeSwitch.expanded
              text: "SWITCH TO " + (rail.scopeMode === "work" ? "PERSONAL" : "WORK")
              color: scopeSwitch.tint
              font { family: Theme.fontFamily; pixelSize: rail.fsMeta - 2; weight: 650 }
            }
          }
          HoverHandler { id: scopeHover }
          TapHandler {
            onTapped: rail.requestScopeMode(rail.scopeMode === "work" ? "personal" : "work")
          }
        }

        // Watchdog state lives here rather than in the header cluster: it is status you
        // glance at, not something you act on mid-stream, and the header had three
        // controls competing in one 60px run. Same grammar as the role switch — glyph at
        // rest (green armed / orange unguarded), expanding on hover to name its action.
        Rectangle {
          id: goalPill
          Layout.alignment: Qt.AlignVCenter
          visible: rail.selectedGoal.length > 0 || rail.selectedIsOrchestrator
          readonly property bool armed: rail.selectedGoal.length > 0
          readonly property color tint: armed ? Theme.green : Theme.orange
          readonly property bool expanded: goalHover.hovered
          implicitWidth: expanded ? goalRow.implicitWidth + 12 : 30
          implicitHeight: 22
          radius: 11
          color: expanded ? Qt.alpha(goalPill.tint, 0.14) : "transparent"
          border.width: 1
          border.color: Qt.alpha(goalPill.tint, expanded ? 0.9 : 0.0)
          Behavior on implicitWidth { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
          Behavior on color { ColorAnimation { duration: 140 } }
          Behavior on border.color { ColorAnimation { duration: 140 } }
          clip: true
          Row {
            id: goalRow
            anchors { left: parent.left; leftMargin: 6; verticalCenter: parent.verticalCenter }
            spacing: 5
            Icon {
              anchors.verticalCenter: parent.verticalCenter
              width: 18; height: 18
              name: "target"
              color: goalPill.tint
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: goalPill.expanded
              text: goalPill.armed ? "RE-ARM" : "SET GOAL"
              color: goalPill.tint
              font { family: Theme.fontFamily; pixelSize: rail.fsMeta - 2; weight: 650 }
            }
          }
          HoverHandler { id: goalHover }
          TapHandler {
            onTapped: rail.prefillComposer(goalPill.armed ? "/goal " + rail.selectedGoal : "/goal ")
          }
        }

        Item { Layout.fillWidth: true }   // push hint chips to the right
        Repeater {
          model: {
            if (rail.pendingAsk && !rail.insert) {
              var pm = rail.pendingAsk.method
              if (pm === "confirm") return [{ k: "y", l: "yes" }, { k: "n", l: "no" },
                                            { k: "t", l: "talk" }, { k: "esc", l: "cancel" }]
              if (pm === "select")  return [{ k: "1-9", l: "pick" }, { k: "t", l: "talk" },
                                            { k: "esc", l: "cancel" }]
              return [{ k: "i", l: "answer" }, { k: "t", l: "talk" }, { k: "esc", l: "cancel" }]
            }
            if (rail.insert) {
              return (rail.featuredStreaming
                ? [{ k: "⏎", l: "steer" }, { k: "C-⏎", l: "queue" }, { k: "esc", l: "interrupt" }]
                : [{ k: "⏎", l: "send" }, { k: "/", l: "commands" }, { k: "esc", l: "normal" }])
                .concat([{ k: "C-v", l: "paste" }])
            }
            if (rail.curSection() === "roster") {
              return [{ k: "⏎", l: "open" }, { k: "n", l: "new" },
                      { k: "x", l: "kill" }, { k: "C-t", l: "collapse" }]
            }
            return [
              { k: "⇥",   l: rail.view === "files" ? "chat" : "files" },
              { k: "⏎",   l: rail.view === "files" ? "open" : "copy" },
              { k: "f",   l: rail.hinting ? "pick" : "links/run" }
            ].concat(rail.featuredStreaming ? [{ k: "esc", l: "interrupt" }, { k: "S-esc", l: "kill tool" }] : [])
          }
          RowLayout {
            spacing: 6
            KeyCap { small: true; px: 11; text: modelData.k }
            CapLabel { px: 12; text: modelData.l }
            Item { width: 6 }
          }
        }
      }
    }
  }

  component InlinePicker: Rectangle {
    required property var entries
    required property int choice
    signal picked(int index)
    width: Math.min(340, parent ? parent.width : 340)
    height: visible ? Math.min(pickerList.contentHeight + 8, 248) : 0
    color: Theme.bg_alt
    radius: Theme.radius !== undefined ? Theme.radius : 10
    border.color: Theme.hairline
    border.width: 1
    z: 12
    ListView {
      id: pickerList
      anchors.fill: parent; anchors.margins: 4; clip: true
      model: entries
      currentIndex: Math.max(0, Math.min(choice, entries.length - 1))
      highlightFollowsCurrentItem: false
      interactive: contentHeight > height
      boundsBehavior: Flickable.StopAtBounds
      onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
      delegate: Rectangle {
        id: pickerRow
        required property var modelData
        required property int index
        readonly property bool sel: index === pickerList.currentIndex
        readonly property bool isSkill: String(modelData).indexOf("skill:") === 0
        width: pickerList.width; height: 32
        radius: 9
        color: sel ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.08)
             : pickerHover.hovered ? Theme.hover : "transparent"
        border.width: 1
        border.color: sel ? Theme.hairline : "transparent"
        Row {
          anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 9
          Item {
            width: 20; height: 20; anchors.verticalCenter: parent.verticalCenter
            Icon {
              anchors.centerIn: parent
              name: pickerRow.isSkill ? "puzzle-piece" : "bolt-lightning"
              width: 14; height: 14
              color: pickerRow.sel ? Theme.fg : Theme.fg_muted
            }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "/" + modelData
            color: pickerRow.sel ? Theme.fg : Theme.fg_secondary
            font.family: Theme.fontFamily; font.pixelSize: 14
            width: parent.width - 29; elide: Text.ElideMiddle
          }
        }
        HoverHandler { id: pickerHover }
        TapHandler { onTapped: picked(pickerRow.index) }
      }
    }
  }

  InlinePicker {
    id: slashPalette
    visible: rail.slashOpen
    anchors { left: parent.left; bottom: chin.top; leftMargin: 20; bottomMargin: 6 }
    width: Math.min(340, parent.width - 40)
    entries: rail.commandMatches
    choice: rail.slashCur
    onPicked: index => {
      rail.slashCur = index
      rail.acceptSlash()
      composerInput.forceActiveFocus()
    }
  }

  FeedbackPill {
    id: feedbackPill
    anchors { horizontalCenter: parent.horizontalCenter; bottom: chin.top; bottomMargin: 10 }
  }

  // Feed row variants
  Component {
    id: groupRow
    Column {
      id: grpCol
      width: parent ? parent.width : 400
      readonly property string myKey: parent && parent.gkey !== undefined ? parent.gkey : ""
      spacing: 3
      Row {
        spacing: 8
        Icon { name: expanded ? "chevron-down" : "chevron-right"; width: 13; height: 13; color: Theme.fg_muted; anchors.verticalCenter: parent.verticalCenter }
        Text {
          text: entry.cmds.length + " " + entry.tool + " calls"
          color: Theme.fg_secondary; font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
          anchors.verticalCenter: parent.verticalCenter
        }
        TapHandler { onTapped: rail.toggleGroupKey(grpCol.myKey) }
      }
      Repeater {
        // Count model for the same reason as the activity list: the cmds array is
        // rebuilt per stream update, and an array model would recreate every line.
        model: expanded ? entry.cmds.length : 0
        Text {
          x: 26
          text: (entry.cmds[index] || {}).text || ""; color: Theme.fg_muted
          font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
          elide: Text.ElideRight; width: 340
        }
      }
    }
  }
  Component {
    id: userBashRow
    Rectangle {
      id: ubCard
      width: parent ? parent.width : 400
      implicitHeight: ubCol.implicitHeight + 18
      radius: 9
      color: Theme.bgDim
      readonly property bool waiting: !entry.failed && !String(entry.result || "").length
                                      && rail.pendingUserBash
                                      && String(rail.pendingUserBash.command || "") === String(entry.command || "")
      border.width: 1
      border.color: entry.failed ? Theme.red : Theme.hairline
      Column {
        id: ubCol
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 9 }
        spacing: 6
        RowLayout {
          width: parent.width
          Icon { name: "chevron-right"; width: 13; height: 13; color: entry.failed ? Theme.red : Theme.orange }
          Text {
            text: "! " + String(entry.command || "")
            color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
            wrapMode: Text.WrapAnywhere; Layout.fillWidth: true
          }
          Text {
            text: entry.failed ? "failed" : (String(entry.result || "").length ? "done" : (ubCard.waiting ? "requested" : "interrupted"))
            color: entry.failed ? Theme.red : Theme.fg_muted
            font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
          }
        }
        Text {
          visible: String(entry.reason || "").length > 0
          width: parent.width; text: String(entry.reason || "")
          color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
          wrapMode: Text.WordWrap
        }
        Rectangle {
          visible: String(entry.result || "").length > 0
          width: parent.width; implicitHeight: ubResult.implicitHeight + 14
          radius: 7; color: Theme.surface0
          Text {
            id: ubResult
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 7 }
            text: String(entry.result || "")
            color: entry.failed ? Theme.red : Theme.fg_secondary
            font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
            wrapMode: Text.WrapAnywhere
          }
        }
      }
    }
  }
  Component {
    id: activityRow
    // Edited files stay visible; Ctrl+Enter toggles only the Bash calls.
    Column {
      id: actCol
      width: parent ? parent.width : 400
      spacing: 9
      readonly property var editItems: rail.turnEditItems(items)
      readonly property var bashItems: rail.turnBashItems(items)
      Row {
        spacing: 7
        Icon {
          visible: actCol.bashItems.length > 0
          name: expanded ? "chevron-down" : "chevron-right"
          width: 12; height: 12; color: Theme.fg_muted; anchors.verticalCenter: parent.verticalCenter
        }
        Text {
          text: summary; color: Theme.fg_muted
          font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
          anchors.verticalCenter: parent.verticalCenter
        }
      }
      Repeater {
        model: actCol.editItems.length
        Loader {
          width: actCol.width
          property var entry: actCol.editItems[index]
          property bool fileSelected: rail.fileSelectOpen && rail.fileChoiceKey === ekey && rail.fileChoiceCur === index
          sourceComponent: editRow
        }
      }
      Repeater {
        // Keep existing Bash delegates mounted when new activity arrives.
        model: expanded ? actCol.bashItems.length : 0
        Loader {
          width: actCol.width
          Component.onCompleted: rail.probeActCreates++
          property var entry: actCol.bashItems[index]
          property string gkey: ekey + "-" + index
          property bool expanded: rail.expandedGroups[gkey] === true
          sourceComponent: bashRow
        }
      }
    }
  }
  Component {
    id: bashRow
    RowLayout {
      spacing: 8
      Icon {
        name: "bolt-lightning"; width: 13; height: 13
        color: Theme.fg_muted; Layout.alignment: Qt.AlignVCenter
      }
      Text {
        text: entry.command
          ? "bash " + String(entry.command).replace(/\s+/g, " ").trim()
          : (entry.text || "")
        color: Theme.fg_secondary
        font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
        elide: Text.ElideRight; maximumLineCount: 1; Layout.fillWidth: true
      }
    }
  }
  Component {
    id: cmdRow
    Column {
      id: cmdCol
      width: parent ? parent.width : 400
      spacing: 6
      // Errors are the one row you must be able to READ: full text, wrapped, red.
      // A failed tool call is an error OUTCOME on a normal row — same red, one line.
      readonly property bool isErr: entry.tool === "error"
      readonly property bool isFailed: entry.failed === true
      // Bash rows carry the raw command — tap toggles it open underneath.
      readonly property bool canExpand: !isErr && String(entry.command || "").length > 0
      readonly property bool open: canExpand && typeof gkey !== "undefined" && rail.expandedGroups[gkey] === true
      RowLayout {
        width: cmdCol.width
        spacing: 8
        Icon {
          name: rail.toolIcon(entry.tool); width: 13; height: 13
          color: (cmdCol.isErr || cmdCol.isFailed) ? Theme.red : Theme.fg_muted
          Layout.alignment: Qt.AlignTop
          Layout.topMargin: Math.max(0, Math.round(rail.fsBody * 1.3 - 13) / 2)
        }
        Text {
          readonly property bool liveNow: {
            rail.agentd ? rail.agentd.curToolGen : 0
            return !!(rail.agentd && entry.id && rail.agentd.curToolIdFor(rail.selectedRaw) === entry.id)
          }
          text: entry.text + (cmdCol.isFailed ? "  — failed" : "")
                + (liveNow ? "  · " + rail.runningToolLabel(rail.selectedRaw).split("· ").pop() : "")
          color: cmdCol.isErr ? Theme.red : (cmdCol.isFailed ? Theme.red : Theme.fg_secondary)
          font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
          wrapMode: cmdCol.isErr ? Text.WordWrap : Text.NoWrap
          elide: cmdCol.isErr ? Text.ElideNone : Text.ElideRight
          maximumLineCount: cmdCol.isErr ? 9999 : 1
          lineHeight: 1.3
          Layout.fillWidth: true
        }
        Icon {
          visible: cmdCol.canExpand
          name: cmdCol.open ? "chevron-down" : "chevron-right"
          width: 11; height: 11; color: Theme.fg_muted
          Layout.alignment: Qt.AlignVCenter
        }
        TapHandler { enabled: cmdCol.canExpand && typeof gkey !== "undefined"; onTapped: rail.toggleGroupKey(gkey) }
      }
      // The full command, monospace on its own ground — selectable-by-eye, wraps.
      Rectangle {
        visible: cmdCol.open
        width: cmdCol.width
        implicitHeight: cmdFull.implicitHeight + 16
        radius: 8
        color: Theme.bgDim
        Text {
          id: cmdFull
          anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8 }
          text: String(entry.command || "")
          color: Theme.fg_secondary
          font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
          wrapMode: Text.WrapAnywhere; lineHeight: 1.35
        }
        TapHandler { onTapped: rail.copyText(String(entry.command || "")) }
      }
    }
  }
  Component {
    id: thinkRow
    RowLayout {
      spacing: 8
      // A small dim dot — a reasoning sub-bullet, distinct from the agent's sparkle avatar.
      // Slot is one line tall and top-aligned, so the dot centres on the first line.
      Item {
        Layout.preferredWidth: 13
        Layout.preferredHeight: Math.round(rail.fsBody * 1.3)
        Layout.alignment: Qt.AlignTop
        Rectangle { width: 4; height: 4; radius: 2; color: Theme.fg_muted; anchors.centerIn: parent }
      }
      Text {
        text: (typeof expanded !== "undefined" && expanded && entry.full) ? entry.full : entry.text
        color: Theme.fg_muted
        font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
        wrapMode: Text.WordWrap; lineHeight: 1.3; Layout.fillWidth: true
        elide: (typeof expanded !== "undefined" && expanded) ? Text.ElideNone : Text.ElideRight
        maximumLineCount: (typeof expanded !== "undefined" && expanded) ? 9999 : 1
      }
      TapHandler { enabled: typeof gkey !== "undefined"; onTapped: rail.toggleGroupKey(gkey) }
    }
  }
  Component {
    id: inlineAttachmentContent
    Column {
      id: attachmentLines
      width: parent ? parent.width : 400
      spacing: 2
      readonly property var lines: rail.inlineAttachmentLines(sourceText)
      Repeater {
        model: attachmentLines.lines
        Flow {
          id: attachmentLine
          readonly property var tokens: modelData
          width: attachmentLines.width
          height: Math.max(24, childrenRect.height)
          Repeater {
            model: attachmentLine.tokens
            Loader {
              property var token: modelData
              sourceComponent: token.kind === "attachment" ? inlineAttachmentChip : inlineAttachmentText
            }
          }
        }
      }
    }
  }
  Component {
    id: inlineAttachmentText
    Item {
      width: attachmentWord.implicitWidth
      height: 24
      Text {
        id: attachmentWord
        anchors.verticalCenter: parent.verticalCenter
        text: token.text
        color: Theme.fg
        font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
      }
    }
  }
  Component {
    id: inlineAttachmentChip
    Item {
      width: imagePill.width + (token.trailing ? 7 : 0)
      height: 24
      Rectangle {
        id: imagePill
        width: imagePillRow.implicitWidth + 16
        height: 24
        radius: 7
        color: Theme.surface0
        border.width: 1
        border.color: Theme.hairline
        Row {
          id: imagePillRow
          anchors.centerIn: parent
          spacing: 6
          Icon { name: "image"; width: 12; height: 12; color: Theme.electric; anchors.verticalCenter: parent.verticalCenter }
          Text {
            text: "Image " + token.number
            color: Theme.fg
            font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }
    }
  }
  Component {
    id: markdownContent
    Column {
      id: markdownRoot
      width: parent ? parent.width : 400
      spacing: 10
      readonly property var blocks: rail.markdownBlocks(sourceText, sourceEntry, sourceOffset)
      Repeater {
        model: markdownRoot.blocks
        Loader {
          width: markdownRoot.width
          property var block: modelData
          property int rowIndex: markdownRoot.parent.rowIndex
          property color bodyColor: markdownRoot.parent.bodyColor
          property bool agentAuthored: markdownRoot.parent.agentAuthored
          sourceComponent: block.kind === "fence" ? fencedCodeBlock : markdownTextBlock
        }
      }
    }
  }
  Component {
    id: markdownTextBlock
    Item {
      id: markdownBlock
      width: parent ? parent.width : 400
      implicitHeight: markdownText.implicitHeight
      TextEdit {
        id: markdownText
        width: parent.width
        height: implicitHeight
        readOnly: true
        selectByMouse: true
        activeFocusOnPress: false
        text: rail.colorizeLinks(rail.badgeAttachments(rail.decorateMarkdown(block, rowIndex)))
        color: bodyColor
        font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
        wrapMode: TextEdit.WordWrap
        textFormat: TextEdit.MarkdownText
        onLinkActivated: (u) => Quickshell.execDetached(["xdg-open", u])
      }
      Repeater {
        model: rail.blockHints(block, rowIndex)
        KeyCap {
          readonly property string marker: "\u200B[" + modelData.label + "]\u200B"
          readonly property int markerPos: markdownText.getText(0, markdownText.length).indexOf(marker)
          readonly property rect markerRect: markerPos >= 0 ? markdownText.positionToRectangle(markerPos) : Qt.rect(-100, -100, 0, 0)
          x: markerRect.x
          y: markerRect.y + (markerRect.height - height) / 2
          z: 2
          small: true
          px: 10
          text: modelData.label
          textColor: Theme.yellow
          TapHandler { onTapped: rail.hintKey(modelData.label) }
        }
      }
    }
  }
  Component {
    id: fencedCodeBlock
    Rectangle {
      id: fence
      width: parent ? parent.width : 400
      implicitHeight: fenceCol.implicitHeight + 20
      radius: 9
      color: Theme.bgDim
      border.width: 1
      border.color: block.runnable && agentAuthored ? rail.summaryColor : Theme.hairline
      readonly property var activeHint: rail.hintForKey(block.key, rowIndex)
      readonly property bool requestsApproval: block.runnable && agentAuthored
      Column {
        id: fenceCol
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
        spacing: 8
        RowLayout {
          width: parent.width
          spacing: 7
          Icon {
            name: fence.requestsApproval ? "chevron-right" : "keyboard"
            width: 13; height: 13
            color: fence.requestsApproval ? rail.summaryColor : Theme.fg_muted
          }
          Text {
            text: fence.requestsApproval ? (block.lang + " · request approval to run") : (block.lang || "code")
            color: fence.requestsApproval ? rail.summaryColor : Theme.fg_muted
            font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
            font.underline: fence.requestsApproval
          }
          Item { Layout.fillWidth: true }
          KeyCap {
            visible: fence.activeHint !== null
            small: true; px: 10
            text: fence.activeHint ? fence.activeHint.label : ""
            textColor: Theme.yellow
            TapHandler { onTapped: if (fence.activeHint) rail.hintKey(fence.activeHint.label) }
          }
        }
        Text {
          width: parent.width
          text: String(block.code || "").replace(/\n$/, "")
          color: fence.requestsApproval ? rail.summaryColor : Theme.fg_secondary
          font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
          wrapMode: Text.WrapAnywhere; lineHeight: 1.35
        }
      }
      HoverHandler { id: fenceHover; enabled: fence.requestsApproval }
      TapHandler { enabled: fence.requestsApproval; onTapped: rail.requestSnippet(block.code) }
    }
  }
  Component {
    id: proseRow
    Column {
      id: proseCol
      width: parent ? parent.width : 400
      spacing: 14
      readonly property var parts: rail.proseParts(entry.text)
      Repeater {
        model: proseCol.parts
        Loader {
          width: proseCol.width
          sourceComponent: modelData.fileRef !== undefined ? fileRefRow : markdownContent
          property var refData: modelData
          property string sourceText: modelData.text || ""
          property int sourceEntry: proseCol.parent.entryIndex
          property int sourceOffset: modelData.offset
          property int rowIndex: proseCol.parent.rowIndex
          property color bodyColor: modelData.summary ? rail.summaryColor : Theme.fg
          property bool agentAuthored: true
        }
      }
    }
  }
  Component {
    id: fileRefRow
    Rectangle {
      width: parent ? parent.width : 400
      height: refLine.implicitHeight + 12
      radius: 6
      color: "transparent"
      // changesGen in the dependency list so the numbers appear when the diff lands
      readonly property var st: (rail.agentd && rail.agentd.changesGen >= 0) ? rail._statFor(refData.path) : null
      border.width: 1
      border.color: Theme.hairline
      RowLayout {
        id: refLine
        anchors.fill: parent
        anchors.leftMargin: 10; anchors.rightMargin: 10
        spacing: 8
        Icon { name: "file-content"; width: 13; height: 13; color: Theme.fg_muted; Layout.alignment: Qt.AlignVCenter }
        Text {
          visible: text.length > 0
          text: rail.fileHintFor(refData.path, rowIndex)
          color: Theme.orange; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta; font.bold: true
        }
        Text {
          text: refData.shown; color: Theme.fg
          font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
          elide: Text.ElideMiddle; Layout.fillWidth: true
        }
          Text {
          visible: !!st
          text: "+" + (st ? st.add : 0); color: Theme.green
          font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
        }
        Text {
          visible: !!st
          text: "-" + (st ? st.del : 0); color: Theme.red
          font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
        }
      }
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: rail.openFileRef(refData.path)
      }
    }
  }
  Component {
    id: editRow
    Rectangle {
      implicitHeight: 30
      radius: 8
      color: fileSelected ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.08) : "transparent"
      border.width: fileSelected ? 1 : 0
      border.color: Theme.hairline
      RowLayout {
        anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
        spacing: 8
        Icon { name: "paintbrush"; width: 13; height: 13; color: Theme.fg_muted; Layout.alignment: Qt.AlignVCenter }
        Text { text: entry.file; color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: rail.fsBody; font.bold: true; elide: Text.ElideMiddle; Layout.fillWidth: true }
        Text { visible: (entry.add + entry.del) > 0; text: "+" + entry.add; color: Theme.green; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta }
        Text { visible: (entry.add + entry.del) > 0; text: "-" + entry.del; color: Theme.red; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta }
      }
      TapHandler { onTapped: rail.openFileRef(entry.path) }
    }
  }
}

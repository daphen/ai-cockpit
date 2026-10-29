import QtQuick
import QtQuick.Effects
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import QsLib
import Heidr

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
  Shortcut {
    sequence: "Ctrl+M"
    context: Qt.ApplicationShortcut
    onActivated: rail.toggleModelPicker()
  }
  // Set by shell.qml from TermView.nvimSocket — the socket THIS instance's nvim listens
  // on. Never rebuild this path here: a guessed shared name is how the rail ended up
  // talking to a socket a newer Cockpit had already unlinked.
  property string nvimSock: ""
  property string localNvimSock: nvimSock
  // The editor reports its view a few hundred ms after a request, so the tab the user
  // picked leads; stale reports are ignored until the editor confirms it.
  property string reportedTab: "code"
  property string workspaceTab: "code"
  property bool _tabAwaiting: false
  onReportedTabChanged: {
    if (reportedTab === workspaceTab) { _tabAwaiting = false; tabConfirm.stop() }
    else if (!_tabAwaiting) workspaceTab = reportedTab
  }
  Timer { id: tabConfirm; interval: 3000; onTriggered: { rail._tabAwaiting = false; rail.workspaceTab = rail.reportedTab } }
  function _requestTab(view) {
    var tab = view === "diff" ? "code" : view
    if (["code", "dashboard", "vault", "plan"].indexOf(tab) < 0) return
    workspaceTab = tab
    _tabAwaiting = tab !== reportedTab
    if (_tabAwaiting) tabConfirm.restart(); else tabConfirm.stop()
  }
  property string remoteNvimSock: ""
  signal editorRequested(string socket)
  property bool focused: false
  readonly property Item composerField: composerInput
  function cursorPoint(key) {
    const i = view === "chat" && key.startsWith("f:") ? _feedIndexOf(key.slice(2)) : -1
    const it = i >= 0 ? feedView.itemAtIndex(i) : null
    return it ? it.restDot.mapToItem(rail, it.restDot.width / 2, it.restDot.height / 2) : null
  }

  property bool caretHeld: false   // a focus glide is still flying to this caret
  signal focusNvim()
  signal requestFocus()   // a click in the rail should pull focus here

  function cockpitEnv(name) {
    return Quickshell.env("COCKPIT_" + name) || Quickshell.env("HEIDR_" + name)
  }

  // Click a row: focus the rail, move the cursor there, and act on it.
  function selectAt(idx) { _blurFeedKey = ""; requestFocus(); exitInsert(); cur = idx }
  function clickAt(idx) { selectAt(idx); activateCur() }
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
    for (var i = 0; i < arr.length; i++) {
      var k = keyOf(arr[i]), sig = sigOf(arr[i])
      if (i < model.count && model.get(i).k === k) {
        if (model.get(i).sig !== sig) {
          model.setProperty(i, "d", JSON.parse(JSON.stringify(arr[i])))
          model.setProperty(i, "sig", sig)
        }
        continue
      }
      var found = -1
      for (var j = i + 1; j < model.count; j++) if (model.get(j).k === k) { found = j; break }
      if (found >= 0) model.move(found, i, 1)
      // A vanished key in this slot is the same row renamed (a streamed row's
      // temporary id replaced by its transcript id): re-key it, don't recreate it.
      else if (i < model.count && !want[model.get(i).k]) model.setProperty(i, "k", k)
      else model.insert(i, { d: JSON.parse(JSON.stringify(arr[i])), sig: sig, k: k })
      if (model.get(i).sig !== sig || found >= 0) {
        model.setProperty(i, "d", JSON.parse(JSON.stringify(arr[i])))
        model.setProperty(i, "sig", sig)
      }
    }
    if (model.count > arr.length) model.remove(arr.length, model.count - arr.length)
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
    indexOffset: rail._feedOffset
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
  // The order tabs are sorted by; held while you move through the tabs, so they only
  // re-sort once the tab list loses focus.
  property var tabRecency: []
  readonly property bool tabsFocused: rosterExpanded && focused && !insert && cur < rSize
  function syncTabRecency() { if (!tabsFocused) tabRecency = recentSelections }
  onRecentSelectionsChanged: syncTabRecency()
  onTabsFocusedChanged: syncTabRecency()
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
  property var lifecycleTarget: null
  property bool lifecycleConfirm: false
  property string lifecycleMessage: ""
  readonly property var lifecycleEntries: lifecycleConfirm
    ? ["Cancel", "CONFIRM REAP " + (lifecycleTarget ? lifecycleTarget.ticket : "") + " — remove worktree and exclusive caches"]
    : ["Turn off — keep files", "REAP — remove worktree and exclusive caches"]
  function _ticketLifecycle(name) {
    var ss = _sessionOf(name)
    if (!ss || ss.parent || !_isRemote(ss.cwd)) return null
    var role = String(ss.profile || ss.role || "")
    if (role.indexOf("orchestrator") >= 0 || String(ss.cwd || "").indexOf("/src/lovable") < 0) return null
    var match = String(ss.cwd || "").match(/(?:^|[-.])(every-\d+)(?:-|$)/i)
    return match ? { session: String(ss.name || name), ticket: match[1].toUpperCase() } : null
  }
  function stopSession(name) {
    var target = String(name || "")
    if (!target || !agentd) return
    var action = _ticketLifecycle(target)
    if (action) {
      lifecycleTarget = action; lifecycleConfirm = false
      requestFocus(); return
    }
    if (target === selectedRaw) {
      var fallback = recentFallback(target)
      activeRaw = fallback; defaultRaw = fallback
    }
    recentSelections = recentSelections.filter(x => x !== target)
    agentd.stop(target)
  }
  function closeLifecycle() { lifecycleTarget = null; lifecycleConfirm = false }
  function chooseLifecycle(index) {
    if (!lifecycleTarget || lifecycleProc.running) return
    if (lifecycleConfirm) {
      if (index === 1) runLifecycle("reap"); else closeLifecycle()
    } else if (index === 0) runLifecycle("off")
    else lifecycleConfirm = true
  }
  function runLifecycle(action) {
    var target = lifecycleTarget
    lifecycleProc.action = action; lifecycleProc.ticket = target.ticket; lifecycleProc.session = target.session
    lifecycleProc.command = [Quickshell.env("HOME") + "/.config/niri/scripts/vm-wt", "--" + action, target.ticket]
    if (action === "reap") {
      var checkout = _sessionCwdOf(target.session), socket = _editorSocket(checkout)
      var parentRepo = checkout.replace(/\/lovable[.-][^/]+$/, "/lovable")
      if (!socket || parentRepo === checkout) {
        lifecycleMessage = "REAP " + target.ticket + " blocked: bound editor or parent repo unavailable"
        feedbackPill.show(lifecycleMessage); closeLifecycle(); return
      }
      var lua = '(function() local m=' + JSON.stringify(checkout) + '; local p=' + JSON.stringify(parentRepo)
        + '; for _,b in ipairs(vim.api.nvim_list_bufs()) do local n=vim.api.nvim_buf_get_name(b); if n~="" and vim.bo[b].modified and (n==m or n:sub(1,#m+1)==m.."/") then return "BLOCK modified file: "..n end end'
        + '; local cwd=(vim.uv or vim.loop).cwd(); if cwd==m or cwd:sub(1,#m+1)==m.."/" then vim.cmd("noautocmd cd "..vim.fn.fnameescape(p)) end; return "OK" end)()'
      lifecycleProc.command = ["sh", "-c", 'r=$(nvim --server "$1" --remote-expr "$2" 2>&1); c=$?; if [ "$c" -ne 0 ] || [ "$r" != OK ]; then echo "$r" >&2; exit 125; fi; exec "$HOME/.config/niri/scripts/vm-wt" --reap "$3"', "reap-check", socket, "luaeval(" + JSON.stringify(lua) + ")", target.ticket]
    }
    lifecycleMessage = (action === "reap" ? "REAP " : "Turn off ") + target.ticket + "…"
    closeLifecycle(); lifecycleProc.running = true
  }
  function keyLifecycle(e) {
    if (e.key === Qt.Key_Escape || (lifecycleConfirm && e.key === Qt.Key_N)) { closeLifecycle(); return true }
    if (lifecycleConfirm && e.key === Qt.Key_Y) { chooseLifecycle(1); return true }
    if (e.key === Qt.Key_1) { chooseLifecycle(0); return true }
    if (e.key === Qt.Key_2 && !lifecycleConfirm) { chooseLifecycle(1); return true }
    return true
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
      onStreamFinished: rail.commands = ["goal", "handover", "reload"]
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
      else if (kind === "inline" && /^https?:\/\/\S+$/.test(String(m[3]).trim()))
        kind = "url"
      var runnable = kind === "fence" && _shellLanguage(m[1])
      if ((mode === "hint" && !(kind === "url" || kind === "file" || runnable)) ||
          (mode === "yank" && !(kind === "url" || kind === "inline" || kind === "fence" || kind === "file"))) continue
      units.push({
        key: "e" + entryIndex + ":p" + (base + m.index),
        kind: runnable ? "shell" : kind,
        value: kind === "fence" ? m[2]
          : kind === "file" ? String(m[6] !== undefined ? (m[6] + (m[7] || "")) : m[3]).trim()
          : kind === "inline" ? m[3] : String(m[4] || m[5] || m[3]).trim(),
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
    // Qt's markdown reader drops the link when the label holds raw HTML, so emit an HTML anchor.
    function link(label, url) {
      return "<a href=\"" + String(url).replace(/&/g, "&amp;").replace(/"/g, "&quot;") + "\"><font color=\""
        + rail.summaryHex + "\"><u>" + safeLabel(label) + "</u></font></a>"
    }
    return String(t || "")
      .replace(/\[([^\]]*)\]\(([^\s)]+)\)/g, (all, label, url) => link(label, url))
      .replace(/`(https?:\/\/[^\s`<>"]+)`/g, (all, url) => link(url, url))
      .replace(/(^|[\s])(https?:\/\/[^\s)<>"]+)/g, (all, pre, url) => pre + link(url, url))
  }

  // agentd emits a `changes` diff only at TURN END, so an idle session's rows would
  // show no numbers. Ask for the on-demand diff instead.
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
    agentd.refreshChanges(selectedRaw, cwd)
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
  function activityEntries(items) {
    var out = []
    for (var entry of turnActivityItems(items)) {
      if (entry.tool === "error") continue
      if (entry.kind === "group") out = out.concat(entry.cmds || [])
      else out.push(entry)
    }
    return out
  }
  function activityRows(items) {
    var out = [], group = null
    for (var entry of activityEntries(items)) {
      var last = out[out.length - 1]
      if (entry.kind !== "edit" && last && last.kind !== "edits" && _isShell(entry) && _isShell(last)
          && commandTitle(entry.command || entry.text) === commandTitle(last.command || last.text)) {
        out[out.length - 1] = Object.assign({}, entry, { runs: (last.runs || [last]).concat([entry]) })
        continue
      }
      if (entry.kind !== "edit") { group = null; out.push(entry); continue }
      if (!group) { group = {kind:"edits",files:[]}; out.push(group) }
      var file = group.files.find(row => row.path === entry.path)
      if (!file) {
        file = Object.assign({}, entry, {add:0,del:0,failed:false,result:"",diffs:[]})
        group.files.push(file)
      }
      var diff = editDiff(entry)
      if (diff && !entry.failed) file.diffs.push(diff)
      if (!entry.failed && !entry.partial) { file.add += Number(entry.add || 0); file.del += Number(entry.del || 0); file.failed = false; file.result = "" }
      if (entry.failed) { file.failed = true; file.id = entry.id; file.detailsText = entry.detailsText; file.result += (file.result ? "\n" : "") + (entry.result || "") }
      file.partial = entry.partial === true
    }
    return out
  }
  function _isShell(entry) { return entry.tool === "bash" || entry.tool === "shell" }
  // A shell command's first line without output plumbing (redirects, a trailing tail/head); quoted text is kept.
  function commandTitle(command) {
    var line = String(command || "").split("\n")[0].replace(/^\s*bash\s+/, "")
    var tokens = line.match(/\d?>>?&\d|&>>?|(?:[^\s"';|&]+|"(?:[^"\\]|\\.)*"?|'[^']*'?)+|&&|\|\||[;|&]/g) || [], kept = []
    for (var i = 0; i < tokens.length; i++) {
      var token = tokens[i]
      if (/^(?:;|\||&&)$/.test(token) && /^(?:tail|head)$/.test(tokens[i + 1] || "")) break
      if (/^(?:\d|&)?>>?$/.test(token)) { i++; continue }
      if (/^(?:\d?>>?&\d|(?:\d|&)?>>?[^&"'][^"']*)$/.test(token)) continue
      kept.push(token)
    }
    return kept.join(" ") || line
  }
  function toolFiles(entry) {
    var out = entry.path ? [String(entry.path)] : []
    var args = JSON.parse(entry.argumentsText || "{}"), argumentPath = args.path || args.file_path || args.filePath
    if (argumentPath && out.indexOf(String(argumentPath)) < 0) out.push(String(argumentPath))
    if (entry.kind === "edit" || entry.tool === "read" || entry.tool === "read_file") return out
    var source = String(entry.result || "") + "\n" + String(entry.argumentsText || "")
    var re = /((?:\/|~\/)?(?:[\w.@-]+\/)+[\w.@-]+\.\w{1,6})(:\d+)?/g, match
    while ((match = re.exec(source)) !== null) {
      var path = match[1] + (match[2] || "")
      if (out.indexOf(path) < 0) out.push(path)
    }
    return out
  }
  readonly property int outputPreviewLines: 10
  // Item mode: Enter on a card walks its actionable items (headers, tool rows, file/diff, show all, copy) with hjkl.
  property bool itemMode: false
  property string itemFocus: ""
  property int itemRow: 0
  property int itemCol: 0
  function _cmdExpandable(entry) {
    return entry.tool !== "error" && !!(entry.result || entry.command) && entry.tool !== "read" && entry.tool !== "read_file"
      && (!sourceTool(entry) || entry.failed)
  }
  function _hiddenOutputLines(entry) {
    if (!entry.result || entry.failed || sourceTool(entry)) return 0
    return Math.max(0, plainToolText(entry.result).replace(/\n+$/, "").split("\n").length - outputPreviewLines)
  }
  // Rows of {key, run} in on-screen order, built from the same keys the delegates render with.
  function cardItemGrid(l) {
    var it = groupedFeed[l], rows = []
    if (!it || it.kind === "user" || !it.items) return rows
    var ekey = "turn-" + (it.key || l), items = it.items
    if (turnThinks(items).length) {
      var reasoningDefault = turnThinks(items).some(claudeThought)
      rows.push([{ key: ekey, run: () => toggleGroupKey(ekey, reasoningDefault) }])
    }
    var tools = activityEntries(items)
    if (!tools.length) return rows
    if (!smallTurn(tools)) rows.push([{ key: ekey + "-tools", run: () => toggleGroupKey(ekey + "-tools") }])
    var compact = activityRows(items), unresolved = unresolvedFailures(tools)
    var currentId = agentd ? agentd.curToolIdFor(selectedRaw) : ""
    var shown = smallTurn(tools) || groupOpen(ekey + "-tools") ? compact : compact.filter(activity => usefulActivity(activity, unresolved, currentId))
    function addFile(file, gkey) {
      var row = [{ key: "open:" + gkey, run: () => openFileRef(file.path) }]
      var diff = entryDiff(file)
      if (file.failed || diff.length) row.push({ key: gkey, run: () => toggleGroupKey(gkey) })
      rows.push(row)
      if (expandedGroups[gkey] === true && !file.failed && diffRows(diff).length > diffPreviewLines)
        rows.push([{ key: gkey + ":all", run: () => toggleGroupKey(gkey + ":all") }])
    }
    for (var i = 0; i < shown.length; i++) {
      var activity = shown[i]
      if (activity.kind === "edits") {
        if (activity.files.length === 1) addFile(activity.files[0], toolKey(toolKey(ekey, activity, i), activity.files[0], 0))
        else for (var f = 0; f < activity.files.length; f++) addFile(activity.files[f], toolKey(toolKey(ekey, activity, i), activity.files[f], f))
        continue
      }
      let gkey = toolKey(ekey, activity, i), entry = activity
      if (!_cmdExpandable(entry)) continue
      rows.push([{ key: gkey, run: () => toggleGroupKey(gkey) }])
      if (expandedGroups[gkey] !== true) continue
      if (_hiddenOutputLines(entry) > 0) rows.push([{ key: gkey + ":all", run: () => toggleGroupKey(gkey + ":all") }])
      var buttons = []
      if (entry.result) buttons.push({ key: "copyout:" + gkey, run: () => copyText(plainToolText(entry.result)) })
      if (entry.command) buttons.push({ key: "copycmd:" + gkey, run: () => copyText(String(entry.command)) })
      if (buttons.length) rows.push(buttons)
    }
    return rows
  }
  function _focusItem(row, col) {
    var grid = cardItemGrid(curLocal())
    if (!grid.length) { exitItemMode(); return }
    itemRow = Math.max(0, Math.min(grid.length - 1, row))
    itemCol = Math.max(0, Math.min(grid[itemRow].length - 1, col))
    itemFocus = grid[itemRow][itemCol].key
  }
  function startItemMode() {
    if (view !== "chat" || cur < rSize || !cardItemGrid(curLocal()).length) return false
    itemMode = true
    _focusItem(0, 0)
    return true
  }
  function exitItemMode() { itemMode = false; itemFocus = "" }
  function keyItemMode(e) {
    if (e.key === Qt.Key_Escape) { exitItemMode(); return true }
    // Rows don't share columns, so vertical moves land on a row's first item.
    if (e.key === Qt.Key_J || e.key === Qt.Key_Down) { _focusItem(itemRow + 1, 0); return true }
    if (e.key === Qt.Key_K || e.key === Qt.Key_Up) { _focusItem(itemRow - 1, 0); return true }
    if (e.key === Qt.Key_L || e.key === Qt.Key_Right) { _focusItem(itemRow, itemCol + 1); return true }
    if (e.key === Qt.Key_H || e.key === Qt.Key_Left) { _focusItem(itemRow, itemCol - 1); return true }
    if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) {
      var grid = cardItemGrid(curLocal()), item = grid[itemRow] && grid[itemRow][itemCol]
      if (item) {
        var key = item.key
        item.run()
        // The grid reshapes after a toggle; keep the ring on the item that was triggered.
        Qt.callLater(function() {
          var next = cardItemGrid(curLocal())
          for (var r = 0; r < next.length; r++) for (var c = 0; c < next[r].length; c++)
            if (next[r][c].key === key) { itemRow = r; itemCol = c; itemFocus = key; return }
          _focusItem(itemRow, itemCol)
        })
      }
      return true
    }
    // Any other key leaves item mode and acts normally.
    exitItemMode()
    return false
  }
  component ItemFocus: Rectangle {
    property string itemKey: ""
    anchors.fill: parent; anchors.margins: -4
    radius: 6; color: "transparent"
    border.width: 1.5; border.color: rail.activeRing
    visible: rail.itemMode && rail.itemFocus === itemKey && itemKey !== ""
  }
  readonly property int diffPreviewLines: 40
  function readRange(entry) {
    var args = {}
    try { args = JSON.parse(entry.argumentsText || "{}") } catch (error) {}
    var first = Number(args.offset) || 0, count = Number(args.limit) || 0
    return first || count ? ":" + (first || 1) + (count ? "-" + ((first || 1) + count - 1) : "+") : ""
  }
  function editDiff(entry) {
    try {
      var details = JSON.parse(entry.detailsText || "{}")
      return details && details.diff ? String(details.diff) : ""
    } catch (error) { return "" }
  }
  function entryDiff(entry) { return entry.diffs ? entry.diffs.join("\n     ...\n") : editDiff(entry) }
  // pi diff lines: a +/-/space marker, a padded line number, then the content; "     ..." marks a gap.
  function diffRows(text) {
    return String(text || "").split("\n").filter(line => line.length).map(function(line) {
      var match = line.match(/^([+\- ])\s*(\d*)\s?(.*)$/)
      return match ? { sign: match[1], number: match[2], text: match[3] } : { sign: " ", number: "", text: line }
    })
  }
  readonly property var codeKeywords: ({
    js: "async await break case catch class const continue default delete do else export extends false finally for function if import in instanceof let new null of property readonly return signal static super switch this throw true try typeof undefined var void while yield",
    nix: "assert else false if import in inherit let null rec then true with",
    lua: "and break do else elseif end false for function goto if in local nil not or repeat return then true until while",
    py: "False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield",
    sh: "case do done elif else esac export fi for function if in local return then while",
    c: "auto bool break case char class const continue default defer do else enum fn for func go if impl int let long match mod mut namespace override package pub return self static struct switch trait true type typedef use var virtual void where while"
  })
  function codeLanguage(path) {
    var ext = String(path || "").split(".").pop().toLowerCase()
    if (["js", "mjs", "cjs", "ts", "tsx", "jsx", "qml", "json"].indexOf(ext) >= 0) return "js"
    if (["sh", "bash", "zsh", "fish"].indexOf(ext) >= 0) return "sh"
    if (["c", "h", "cc", "cpp", "hpp", "rs", "go", "java", "kt", "swift", "cs"].indexOf(ext) >= 0) return "c"
    return ["nix", "lua", "py"].indexOf(ext) >= 0 ? ext : ""
  }
  // Home-relative or session-relative path with the directory dimmed and the file name bright.
  function pathMarkup(path) {
    var shown = String(path || "")
    if (selectedCwd && shown.indexOf(selectedCwd + "/") === 0) shown = shown.slice(selectedCwd.length + 1)
    else if (shown.indexOf(homeDir + "/") === 0) shown = "~" + shown.slice(homeDir.length)
    var cut = shown.lastIndexOf("/")
    return cut < 0 ? _styledText(shown)
      : "<font color=\"" + Theme.fg_muted + "\">" + _styledText(shown.slice(0, cut + 1)) + "</font>" + _styledText(shown.slice(cut + 1))
  }
  readonly property string homeDir: Quickshell.env("HOME") || ""
  function _styledText(text) {
    return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/\t/g, "   ").replace(/ /g, "&nbsp;")
  }
  // One line of code as StyledText: comments, strings, numbers and keywords. Deliberately lexical, not a parser.
  function highlightCode(text, language) {
    text = String(text || "")
    if (!language) return _styledText(text)
    var comment = language === "lua" ? "--.*" : ["nix", "sh", "py"].indexOf(language) >= 0 ? "#.*" : "//.*"
    var token = new RegExp("(" + comment + ")|(\"(?:[^\"\\\\]|\\\\.)*\"?|'(?:[^'\\\\]|\\\\.)*'?|`[^`]*`?)|\\b(\\d[\\w.]*)|\\b(true|false|null|nil|None|True|False|undefined|nullptr)\\b|\\b(" + codeKeywords[language].split(" ").join("|") + ")\\b", "g")
    var out = "", last = 0, match
    while ((match = token.exec(text)) !== null) {
      if (!match[0].length) { token.lastIndex++; continue }
      var color = match[1] ? Theme.syntaxComment : match[2] ? Theme.syntaxString : match[3] ? Theme.syntaxNumber
                : match[4] ? Theme.syntaxBoolean : Theme.syntaxKeyword
      var piece = "<font color=\"" + color + "\">" + _styledText(match[0]) + "</font>"
      out += _styledText(text.slice(last, match.index)) + (match[1] ? "<i>" + piece + "</i>" : piece)
      last = token.lastIndex
    }
    return out + _styledText(text.slice(last))
  }
  function _attemptKey(entry) {
    return entry.kind === "edit" ? "edit:" + String(entry.path || "") : String(entry.tool || "") + ":" + String(entry.command || entry.text || "")
  }
  // A failure is resolved when a later call on the same file (or the same command) in the turn succeeded.
  function unresolvedFailures(tools) {
    return tools.filter((tool, index) => tool.failed === true
      && !tools.slice(index + 1).some(later => later.failed !== true && later.partial !== true && _attemptKey(later) === _attemptKey(tool)))
  }
  // A turn this small gains nothing from a "Work details" header; its rows show directly.
  function smallTurn(tools) { return tools.length <= 2 }
  function usefulActivity(activity, unresolved, currentId) {
    if (activity.kind === "edits") return true
    var rows = activity.kind === "group" ? (activity.cmds || []) : [activity]
    return rows.some(row => (currentId && row.id === currentId) || (row.runs || [row]).some(run => unresolved.indexOf(run) >= 0)
      || (!row.failed && !sourceTool(row) && ["read", "read_file", "ls", "list", "glob", "find"].indexOf(row.tool) < 0))
  }
  function sourceTool(entry) {
    return ["read", "read_file", "edit", "write", "create", "str_replace", "grep", "ripgrep", "search_files"].indexOf(entry.tool) >= 0
      || ((entry.tool === "bash" || entry.tool === "shell") && /^\s*(?:rg|grep|cat|sed|head|awk|git\s+(?:diff|show))\b/.test(entry.command || ""))
  }
  function plainToolText(text) {
    return String(text || "").replace(/\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\))/g, "")
      .replace(/\r\n?/g, "\n").replace(/[\x00-\x08\x0b-\x1f\x7f]/g, "")
  }
  function errorText(entry) {
    var text = plainToolText(entry.result), lines = text.split("\n").filter(line => line.trim().length)
    var first = text.match(/(\{[\s\S]*\})/), message = "", status = "", title = ""
    if (first) {
      try {
        var data = JSON.parse(first[1])
        message = typeof data.message === "string" ? data.message : ""
        title = typeof data.error === "string" ? data.error.replace(/_/g, " ") : ""
        if (title) title = title.charAt(0).toUpperCase() + title.slice(1)
        if (data.status) status = "HTTP " + data.status
      } catch (error) {}
    }
    if (!message) {
      var diagnostic = lines.filter(line => /^\s*(?:(?:\w+\.)*\w*Error:|(?:WARN|ERROR)\b.*?Error:|fatal:|gh:|bash:|Permission denied|Tool call .*not executed|edits\[\d+\]|Found \d+ occurrences|could not|cannot|timed out|not found)/i.test(line))
      if (diagnostic.length) message = diagnostic[diagnostic.length - 1].replace(/^.*?Error:\s*/i, "")
    }
    if (!message && !first && !sourceTool(entry) && entry.tool !== "bash" && entry.tool !== "shell") message = lines[0] || ""
    if (!message) message = "Command failed"
    var code = text.match(/Command exited with code\s+(-?\d+)/)
    var details = entry.detailsText ? JSON.parse(entry.detailsText) : {}
    var exitCode = details.exitCode !== undefined ? details.exitCode : code ? Number(code[1]) : undefined
    return (title ? title + "\n" : "") + [message, status, exitCode !== undefined ? "Exit code " + exitCode : ""].filter(value => value.length).join(" · ")
  }
  function errorDetails(entry) {
    var match = plainToolText(entry.result).match(/(\{[\s\S]*\})/)
    if (!match) return ""
    try { return JSON.stringify(JSON.parse(match[1]), null, 2) } catch (error) { return "" }
  }
  readonly property string sessionUsage: feed.filter(item => item.tool === "usage").map(item => item.text).join("\n")
  function activityFileRefs(item) {
    var out = []
    if (!item || item.kind !== "turn") return out
    for (var entry of activityEntries(item.items))
      if (entry.kind === "edit" && entry.path && out.indexOf(entry.path) < 0) out.push(entry.path)
    return out
  }
  function toolKey(cardKey, entry, index) { return entry.id ? "tool:" + selectedRaw + ":" + entry.id : cardKey + "-tool-" + index }
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
    openInNvim(line ? r.substring(0, r.length - line[0].length) : r, selectedCwd, line ? Number(line[1]) : 1)
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
    var source = String(text || ""), re = /```([a-zA-Z0-9_-]*)[ \t]*\n([\s\S]*?)(?:```|$)/g
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
    return /@?[\w~./-]*heidr-pastes\/[^\s"']+|(?:^|[\s`(])[\w@.-]+\.(?:png|jpe?g|gif|webp|bmp|svg)(?=$|[\s`),.;:!?])/i.test(String(text || ""))
  }
  function imageAttachmentLabel(text, number) {
    var source = String(text || "").trim().replace(/[),.;:!?]+$/, "").replace(/^`+|`+$/g, "")
    if (source.indexOf("heidr-pastes/") >= 0) return "Image " + number
    return source.split("/").pop()
  }
  function fileBadgeName(text) {
    var match = String(text || "").trim().match(/^`([A-Za-z0-9_][\w.@-]*\.([A-Za-z][A-Za-z0-9]{0,7}))`[),.;:!?]*$/)
    if (!match) return ""
    var extensions = [
      "c", "cc", "cpp", "css", "desktop", "fish", "go", "h", "hpp", "html",
      "js", "json", "jsonc", "jsx", "kdl", "lua", "md", "nix", "py", "qml",
      "rs", "scss", "service", "sh", "toml", "ts", "tsx", "yaml", "yml"
    ]
    return extensions.indexOf(match[2].toLowerCase()) >= 0 ? match[1] : ""
  }
  function hasFileBadges(text) {
    var candidates = String(text || "").match(/`[^`\s]+`[),.;:!?]*/g) || []
    for (var i = 0; i < candidates.length; i++) if (fileBadgeName(candidates[i])) return true
    return false
  }
  function hasInlineBadges(text) {
    return hasImageAttachments(text) || hasFileBadges(text)
  }
  function inlineAttachmentLines(text) {
    var number = 0
    return String(text || "").split("\n").map(function (line) {
      var tokens = [], re = /@?[\w~./-]*heidr-pastes\/[^\s"']+[ \t]*|`[^`\n]+`[ \t]*|[^\s]+[ \t]*/g, match
      while ((match = re.exec(line)) !== null) {
        var raw = match[0], image = hasImageAttachments(raw)
        var fileName = image ? "" : fileBadgeName(raw)
        var codeMatch = (!image && !fileName) ? String(raw).trim().match(/^`([^`]+)`[),.;:!?]*$/) : null
        if (image) number++
        tokens.push({ kind: image ? "image" : (fileName ? "file" : (codeMatch ? "code" : "text")),
                      text: raw, number: number,
                      label: image ? imageAttachmentLabel(raw, number) : (fileName || (codeMatch ? codeMatch[1] : "")),
                      trailing: /[ \t]$/.test(raw) })
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
  function _editorSocket(cwd) { return scopeMode === "work" && _isRemote(cwd) ? remoteNvimSock : localNvimSock }
  function _contextSocket(data) {
    if (!data.editor) return localNvimSock
    for (var socket of [localNvimSock, remoteNvimSock])
      if (socket && socket.split("/").pop() === data.editor) return socket
    return ""
  }
  // ── image paste ─────────────────────────────────────────────────────────────
  property var pastedImages: []   // filenames pasted this session, shown as composer chips
  readonly property string composerKey: scopeMode + "/" + selectedRaw
  property var codeDrafts: ({})
  property var planDrafts: ({})
  readonly property var planDraft: planDrafts[composerKey] || null
  property var planMenu: null
  property int planChoice: 0
  onComposerKeyChanged: planMenu = null
  readonly property var codeAttachments: codeDrafts[composerKey] || []
  FileView { id: editorContextFile; preload: false; blockAllReads: true; printErrors: false }
  function receiveEditorContext(input) {
    var data
    try {
      if (String(input).charAt(0) === "{") data = JSON.parse(input)
      else { editorContextFile.path = input; data = JSON.parse(editorContextFile.text()) }
    } catch (e) { return "could not read editor context" }
    if (data.session !== selectedRaw || data.mode !== scopeMode) return "selected session changed; attach again"
    if (!_contextSocket(data)) return "editor does not belong to this window"
    if (data.kind === "menu") {
      planMenu = data; planChoice = 0; exitInsert(); requestFocus()
      return "accepted"
    }
    if (data.kind === "compose") {
      if (planDraft) return "finish or remove the current plan draft first"
      var plans = Object.assign({}, planDrafts); plans[composerKey] = data; planDrafts = plans
    } else if (data.kind === "code") {
      var drafts = Object.assign({}, codeDrafts)
      drafts[composerKey] = codeAttachments.concat([data]); codeDrafts = drafts
    } else return "unsupported editor context"
    requestFocus(); enterInsert()
    return "accepted"
  }
  function removeCode(index) {
    var drafts = Object.assign({}, codeDrafts), items = codeAttachments.slice()
    items.splice(index, 1); drafts[composerKey] = items; codeDrafts = drafts
  }
  function clearCode(key) {
    var drafts = Object.assign({}, codeDrafts); delete drafts[key || composerKey]; codeDrafts = drafts
  }
  function removePlanDraft(key) {
    var drafts = Object.assign({}, planDrafts); delete drafts[key || composerKey]; planDrafts = drafts
  }
  function requestPlanMenu() {
    if (!nvimSock) return
    Quickshell.execDetached(["nvim", "--server", nvimSock, "--remote-expr", "luaeval('require(\"plan-nvim\").menu()')"])
  }
  function choosePlan(index) {
    if (!planMenu) return
    var socket = _contextSocket(planMenu)
    if (!socket) return
    var action = planMenu.actions ? planMenu.actions[index] : index + 1
    var lua = 'require("plan-nvim").menu(' + JSON.stringify(action) + ',' + JSON.stringify(planMenu.path) + ')'
    planMenu = null
    if (action === "cancel") return
    Quickshell.execDetached(["nvim", "--server", socket, "--remote-expr", "luaeval(" + JSON.stringify(lua) + ")"])
  }
  FileView {
    id: planSubmitFile
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/cockpit-plan-submit-" + rail.instanceName + ".json"
    blockWrites: true
  }
  Process {
    id: planSubmit
    property string key: ""
    property string draftText: ""
    property var codes: []
    stdout: StdioCollector { id: planSubmitOutput }
    onExited: (code, status) => {
      if (code !== 0 || planSubmitOutput.text.trim() !== "sent") { feedbackPill.show("Plan action was not sent; reopen its menu"); return }
      rail.removePlanDraft(key)
      if (rail.codeDrafts[key] === codes) rail.clearCode(key)
      if (rail.composerKey === key && composerInput.text === draftText) composerInput.text = ""
    }
  }
  function sendPlanDraft() {
    if (planSubmit.running || !planDraft) return
    var socket = _contextSocket(planDraft)
    if (!socket) return
    planSubmit.key = composerKey; planSubmit.draftText = composerText; planSubmit.codes = codeDrafts[composerKey]
    var payload = JSON.stringify({ id: planDraft.id, text: attachRefs(composerText) }), lua
    if (socket === remoteNvimSock)
      lua = 'require("plan-nvim").submit_compose(vim.json.decode(' + JSON.stringify(payload) + '))'
    else {
      planSubmitFile.setText(payload)
      lua = 'require("plan-nvim").submit_compose(' + JSON.stringify(planSubmitFile.path) + ')'
    }
    planSubmit.command = ["nvim", "--server", socket, "--remote-expr", "luaeval(" + JSON.stringify(lua) + ")"]
    planSubmit.running = true
  }
  // pi needs @references in the prompt: each [image N] token is replaced IN PLACE
  // by its file ref at send time. A token the user deleted sends nothing — deletion
  // is the drop gesture.
  function attachRefs(t) {
    var text = String(t || "").replace(/\[(img\d+)\]/g, function (all, stem) {
      var f = ""
      for (var i = 0; i < pastedImages.length; i++)
        if (String(pastedImages[i]).indexOf(stem + ".") === 0) { f = pastedImages[i]; break }
      if (!f) return all
      return "@" + (pasteViaSsh ? vmPasteDir : pasteDir) + "/" + f
    })
    for (var code of codeAttachments) {
      var fence = "```"
      while (code.text.indexOf(fence) >= 0) fence += "`"
      text += "\n\nSelected code: " + code.path + ":" + code.l1 + "-" + code.l2
        + "\n" + fence + (code.lang || "") + "\n" + code.text + "\n" + fence
        + (code.fromPlan ? "\nAnswer in chat; do not edit the plan." : "")
    }
    return text
  }
  readonly property bool pasteViaSsh: _sessionCwdOf(selectedRaw).indexOf(
    "/home/" + (cockpitEnv("VM_USER") || "david_karlsson_lovable_dev") + "/") === 0
  readonly property string vmPasteDir: "/home/" + (cockpitEnv("VM_USER") || "david_karlsson_lovable_dev") + "/.cache/heidr-pastes"
  readonly property string pasteDir: Quickshell.env("HOME") + "/.cache/heidr-pastes"
  Process {
    id: pasteProc
    stdout: StdioCollector {
      onStreamFinished: {
        var out = String(this.text || "").trim()
        if (!out) { feedbackPill.show("Screenshot capture failed"); return }
        if (out === "NOIMAGE") { composerInput.paste(); return }
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
  // VM caches cannot enter a project commit.
  function _pushPasteRemote(name) {
    if (!pasteViaSsh) return
    var vmuser = cockpitEnv("VM_USER") || "david_karlsson_lovable_dev"
    var host = cockpitEnv("VM_HOST")
             || ((cockpitEnv("VM") || "dev-heidr-2a39") + ".workstation.lovable.net")
    var ssh = "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
            + " -o ControlMaster=auto -o ControlPath=" + Quickshell.env("XDG_RUNTIME_DIR") + "/heidr-vm-cm"
            + " -o ControlPersist=600 -o ConnectTimeout=15"
    var rdir = vmPasteDir
    var local = pasteDir + "/" + name
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
      'd=' + JSON.stringify(rail.pasteDir) + '; mkdir -p "$d" || exit 0; ' +
      'g=$(cd "$d/.." && git rev-parse --absolute-git-dir 2>/dev/null); ' +
      'if [ -n "$g" ]; then grep -qxF ".heidr-pastes/" "$g/info/exclude" 2>/dev/null || { mkdir -p "$g/info"; echo ".heidr-pastes/" >> "$g/info/exclude"; }; fi; ' +
      't=$(wl-paste --list-types 2>/dev/null | grep -m1 "^image/"); ' +
      '[ -n "$t" ] || { echo NOIMAGE; exit 0; }; ' +
      'e=${t#image/}; [ "$e" = jpeg ] && e=jpg; [ "$e" = svg+xml ] && e=svg; ' +
      // The counter survives expiry; its lock serializes captures across windows.
      'exec 9<>"$d/.sequence" || exit 1; flock 9 || exit 1; ' +
      'n=$(cat "$d/.sequence"); if [ -z "$n" ]; then n=$(ls "$d" | grep -oE "^img[0-9]+" | cut -c4- | sort -n | tail -n1); fi; ' +
      'n=$((${n:-0}+1)); printf "%s\\n" "$n" > "$d/.sequence" || exit 1; ' +
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
    landNvim(selectedRaw, "plan")
  }
  Process {
    id: planLookup
    property string sid: ""
    property string plan: ""
    property string cwd: ""
    property string mode: ""
    stdout: StdioCollector { id: planLookupOutput }
    onExited: (code, status) => {
      var session = rail._sessionOf(sid)
      if (rail.selectedRaw !== sid || rail.scopeMode !== mode || !session
          || String(session.plan || "") !== plan || String(session.cwd || "") !== cwd) return
      if (code !== 0) { feedbackPill.show("Could not check the VM checkout plan"); return }
      rail.landNvim(sid, "plan", planLookupOutput.text.trim() === "1" ? rail.remoteNvimSock : rail.localNvimSock)
    }
  }
  function landNvim(sid, view, chosenSocket) {
    if (!sid || !agentd) return
    if (view === undefined && workspaceTab === "vault") { view = "vault"; chosenSocket = localNvimSock }
    else if (view === undefined && workspaceTab === "dashboard") view = "dashboard"
    var ss = _sessionOf(sid)
    var cwd = ss ? String(ss.cwd || "") : "", plan = ss ? String(ss.plan || "") : ""
    if (view === undefined && workspaceTab === "plan") view = plan ? "plan" : "code"
    if (!cwd) return
    var socket = chosenSocket || _editorSocket(cwd)
    if (!socket) { feedbackPill.show("VM editor is connecting"); return }
    _requestTab(view)
    if (!chosenSocket && socket === remoteNvimSock && view === "plan" && plan) {
      if (planLookup.running) return
      planLookup.sid = sid; planLookup.plan = plan; planLookup.cwd = cwd; planLookup.mode = scopeMode
      planLookup.command = ["nvim", "--server", socket, "--remote-expr", "luaeval(" + JSON.stringify('vim.fn.filereadable(' + JSON.stringify(cwd + "/.plans/" + plan + ".md") + ')') + ")"]
      planLookup.running = true
      return
    }
    _landedFor = sid + "@" + cwd + "#" + plan
    editorRequested(socket)
    Quickshell.execDetached(["nvim", "--server", socket, "--remote-expr", "v:lua." + _workspaceCall(sid, view, socket, chosenSocket)])
  }
  function _workspaceCall(sid, view, socket, chosenSocket) {
    var ss = _sessionOf(sid), cwd = String(ss.cwd || ""), plan = String(ss.plan || "")
    var localCwd = chosenSocket === localNvimSock
      ? Quickshell.env("HOME") + "/personal/notes/storage" : cwd
    var latest = view === "plan" || view === "vault" || (view === "code" && !agentd.isBusy(sid)) ? "" : String(agentd.lastEditFor(sid) || "")
    if (latest && latest.charAt(0) !== "/") latest = localCwd + "/" + latest
    return 'require("cockpit").workspace(' + [scopeMode, sid, localCwd, plan, view || "", latest, String(ss.profile || ""), String(ss.scope || ""), rail._isRemote(cwd) && socket !== remoteNvimSock ? cwd : ""].map(function(value) { return JSON.stringify(value) }).join(",") + ')'
  }
  function showWorkspace(view) {
    landNvim(selectedRaw, view, view === "vault" ? localNvimSock : "")
    focusNvim()
  }

  function openInNvim(path, baseCwd, line, column) {
    if (!path || !String(path).length || !nvimSock.length) return
    var p = String(path), alternate = ""
    if (p.indexOf("~/") === 0) p = Quickshell.env("HOME") + p.substring(1)
    if (p.charAt(0) !== "/") {
      var cwd = String(baseCwd || changesCwd || "")
      var repoPath = cwd ? cwd + "/" + p : p
      if (/^(inbox|journal|meetings|memory|plans|references|reviews)\//.test(p)) {
        alternate = repoPath
        p = Quickshell.env("HOME") + "/personal/notes/storage/" + p
      } else p = repoPath
    }
    var vault = Quickshell.env("HOME") + "/personal/notes/storage"
    var inVault = p.indexOf(vault + "/") === 0
    var socket = inVault ? localNvimSock : _editorSocket(p)
    if (!socket) { feedbackPill.show("VM editor is connecting"); return }
    editorRequested(socket)
    _requestTab(inVault ? "vault" : "code")
    var land = _sessionOf(selectedRaw) && String(_sessionOf(selectedRaw).cwd || "")
      ? _workspaceCall(selectedRaw, inVault ? "vault" : "code", socket, inVault ? localNvimSock : "") + '; ' : ''
    var row = Math.max(1, Number(line) || 1), col = Math.max(1, Number(column) || 1)
    var lua = '(function() ' + land + 'local p=' + JSON.stringify(p) + '; local alt=' + JSON.stringify(alternate)
      + '; if vim.fn.filereadable(p)~=1 and alt~="" and vim.fn.filereadable(alt)==1 then p=alt end'
      + '; if vim.fn.filereadable(p)~=1 then vim.notify("file no longer exists: "..p, vim.log.levels.WARN); return "" end'
      + '; vim.cmd.CockpitEdit(p); if vim.api.nvim_buf_get_name(0)~=p then return "" end'
      + '; vim.api.nvim_win_set_cursor(0, {' + row + ',' + (col - 1) + '}); return "" end)()'
    Quickshell.execDetached(["nvim", "--server", socket, "--remote-expr", "luaeval(" + JSON.stringify(lua) + ")"])
    rail.focusNvim()
  }
  function openRequestedFile(sid, path, line, column) {
    if (sid !== selectedRaw) return
    openInNvim(path, _sessionCwdOf(sid), line, column)
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
  function turnThinks(items) { return (items || []).filter(x => x.kind === "think") }
  function claudeThought(item) { return /(^|[/.])claude-/i.test(String(item.model || "")) }
  function turnUserBash(items) { return (items || []).filter(x => x.kind === "userbash") }
  // Compact one-line summary of a turn's TOOL activity (thinking is shown, not
  // counted): "4 bash · 6 read · edited file.ts".
  function turnActivitySummary(items) {
    var counts = {}, editFiles = [], interrupts = 0, errors = 0
    for (var i = 0; i < (items || []).length; i++) {
      var it = items[i]
      if (it.kind === "text" || it.kind === "think" || it.kind === "userbash") continue
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
      && !(x.kind === "cmd" && x.tool === "info"))
  }
  function turnInfos(items) {
    return (items || []).filter(x => x.kind === "cmd" && x.tool === "info").map(x => String(x.text || ""))
  }

  function feedCopyTarget(item) {
    if (!item) return ""
    if (item.kind === "turn") {
      var prose = turnProse(item.items).map(x => x.text).join("\n\n")
      return prose || activityEntries(item.items).map(x => x.result || x.command || x.argumentsText || x.text || "").join("\n\n")
    }
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
  readonly property int fsHeader: Theme.fontSize + 6
  readonly property int fsName:   Theme.fontSize + 4
  readonly property int fsBody:   Theme.fontSize + 3
  readonly property int fsMeta:   Theme.fontSize + 2
  readonly property int bodyLeading: Math.round(fsBody * 1.5)
  readonly property int metaLeading: Math.round(fsMeta * 1.5)
  readonly property string privateFontDir: rail.instanceName === "personal" ? "file://" + Quickshell.env("HOME") + "/.local/share/fonts/Timeless-1.094/" : ""
  FontLoader { id: privateMessageFont; source: rail.privateFontDir ? rail.privateFontDir + "TimelessSans-SansRegular.ttf" : "" }
  FontLoader { id: privateBoldFont; source: rail.privateFontDir ? rail.privateFontDir + "TimelessSans-SansBold.ttf" : "" }
  FontLoader { id: privateBoldItalicFont; source: rail.privateFontDir ? rail.privateFontDir + "TimelessSans-SansBoldItalic.ttf" : "" }
  FontLoader { id: privateLabelFont; source: rail.privateFontDir ? rail.privateFontDir + "TimelessSans-GroteskRegular.ttf" : "" }
  FontLoader { source: rail.privateFontDir ? rail.privateFontDir + "TimelessSans-GroteskMedium.ttf" : "" }
  FontLoader { source: rail.privateFontDir ? rail.privateFontDir + "TimelessSans-GroteskSemibold.ttf" : "" }
  FontLoader { source: rail.privateFontDir ? rail.privateFontDir + "TimelessSans-GroteskBold.ttf" : "" }
  readonly property string messageFontFamily: privateMessageFont.status === FontLoader.Ready ? "Timeless Sans Sans" : "Geist"
  readonly property string messageBoldFontFamily: privateBoldFont.status === FontLoader.Ready && privateBoldItalicFont.status === FontLoader.Ready ? "Timeless Sans Sans Bold" : ""
  readonly property string labelFontFamily: privateLabelFont.status === FontLoader.Ready ? privateLabelFont.name : Theme.fontFamily
  function labelFontStyle(weight) {
    if (privateLabelFont.status !== FontLoader.Ready) return ""
    return weight >= 700 ? "Grotesk Bold" : weight >= 600 ? "Grotesk Semibold" : weight >= 500 ? "Grotesk Medium" : "Grotesk Regular"
  }
  readonly property int messageBodyWeight: 400
  readonly property int messageMetaWeight: 500
  readonly property color lavenderAccent: Theme.mode === "light" ? "#7C68C9" : "#C4B5FD"
  readonly property color skyAccent: Theme.mode === "light" ? "#287FA6" : "#7DD3FC"
  readonly property color silverAccent: Theme.mode === "light" ? "#6F777C" : "#C2C8CC"
  readonly property color mintAccent: Theme.mode === "light" ? "#3F8C69" : "#86D7B0"
  readonly property color goldAccent: Theme.mode === "light" ? "#9A6500" : "#F2C572"
  readonly property color codePanelColor: Theme.mode === "light" ? "#FFFFFF" : Qt.tint(userCardBottom, Qt.rgba(1, 1, 1, 0.08))
  readonly property color codePanelBorder: Theme.mode === "light" ? Theme.hairline : Qt.rgba(1, 1, 1, 0.32)
  readonly property color userCardTop: Theme.mode === "light" ? "#FFFFFF" : Qt.lighter(Theme.surface0, 1.25)
  readonly property color userCardBottom: Theme.mode === "light" ? "#FDFDFD" : Qt.lighter(Theme.surface0, 1.2)

  // Turn-recap summary hue — electric, brightened + desaturated, with the hue
  // nudged off electric's blue-violet toward sky's blue so it doesn't read pink.
  //   summaryHueMix 0 = electric hue (violet), 1 = sky hue (blue)
  //   summarySat    <1 desaturates (calmer)
  //   summaryLight  >1 brightens toward white
  readonly property real summaryHueMix: 0.6
  readonly property real summarySat: 0.5
  readonly property real summaryLight: Theme.mode === "light" ? 0.72 : 1.3
  readonly property color summaryColor: Qt.hsla(
    lavenderAccent.hslHue * (1 - summaryHueMix) + Theme.sky.hslHue * summaryHueMix,
    Math.max(0, Math.min(1, lavenderAccent.hslSaturation * summarySat)),
    Math.max(0, Math.min(1, lavenderAccent.hslLightness * summaryLight)),
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
    if (agentd && agentd.isInterrupting(sid)) return "stopping — waiting for confirmation"
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
  readonly property color activeRing: Qt.alpha(Theme.mode === "light" ? "#242424" : "#FAFAFA", 0.6)
  readonly property color cardRing: Qt.alpha(Theme.mode === "light" ? "#242424" : "#FAFAFA", 0.18)
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
    if (tool === "mcp" || tool === "agent_read") return "puzzle-piece"
    if (tool === "read" || tool === "read_file") return "file-content"
    if (tool === "grep" || tool === "ripgrep" || tool === "search_files"
        || tool === "glob" || tool === "find") return "magnifier"
    if (tool === "bash" || tool === "shell") return "keyboard"
    if (tool === "ask") return "msg-bubble-user"
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
    onLoaded: {
      var names = String(text() || "").split("\n").map(x => x.trim()).filter(x => x.length)
      rail.savedRaw = names.length ? names[0] : ""
      rail.recentSelections = rail.recentSelections.concat(names.filter(x => rail.recentSelections.indexOf(x) < 0)).slice(0, 20)
      rail._recomputeDefault()
    }
  }
  Process { id: selectionWrite }
  function rememberSelection(name) {
    if (!name) return
    selectionWrite.running = false
    selectionWrite.command = ["sh", "-c", 'mkdir -p "$1"; printf %s "$2" > "$3"',
                              "sh", Quickshell.env("HOME") + "/.local/state/cockpit", recentSelections.join("\n"), selectionStatePath]
    selectionWrite.running = true
  }
  function _recomputeDefault() {
    if (!live || !agentd || !agentd.settled) { defaultRaw = ""; return }
    var ownerScope = recordedOrchScope || orchScope
    var eligible = s => !(scopeMode === "work" && ownerScope && s.profile === "lovable-orchestrator" && s.scope !== ownerScope)
    if (savedRaw && liveSessions.some(s => s.name === savedRaw && eligible(s))) { defaultRaw = savedRaw; return }
    var owner = scopeMode === "work" ? liveSessions.find(s => s.profile === "lovable-orchestrator" && s.scope === ownerScope) : null
    if (owner) { defaultRaw = owner.name; return }
    if (defaultRaw && liveSessions.some(s => s.name === defaultRaw && eligible(s))) return
    var available = liveSessions.filter(eligible)
    var roots = available.filter(s => !s.parent)
    var pool = (roots.length ? roots : available).slice()
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
    function onAvailableModelsGenChanged() { rail.refreshModelEntries() }
    function onModelChangeResult(sid, success, detail) {
      if (sid === rail.selectedRaw) feedbackPill.show(success ? "Model changed: " + detail : "Model change failed: " + detail)
    }
  }
  readonly property string selectedRaw: activeRaw || defaultRaw
  readonly property string selectedModelId: {
    for (var mi = 0; mi < liveSessions.length; mi++)
      if (liveSessions[mi].name === selectedRaw) return String(liveSessions[mi].model || "")
    return ""
  }
  function modelLabel(modelId) {
    var id = String(modelId || "").split("/").pop()
    return id.toUpperCase().replace(/-/g, " ")
  }
  readonly property string selectedModelLabel: modelLabel(selectedModelId)
  property bool hintsOpen: false
  property bool modelOpen: false
  property var modelEntries: []
  property int modelCur: 0
  function refreshModelEntries() {
    if (!agentd || !selectedRaw) { modelEntries = []; modelCur = 0; return }
    modelEntries = agentd.modelsFor(selectedRaw).filter(function(m) { return m && m.id && m.provider })
    modelCur = Math.max(0, modelEntries.findIndex(function(m) {
      return String(m.provider) + "/" + String(m.id) === selectedModelId
        || String(m.id) === selectedModelId
    }))
  }
  function toggleModelPicker() {
    modelOpen = !modelOpen
    if (!modelOpen) return
    exitInsert()
    requestFocus()
    refreshModelEntries()
    if (agentd && selectedRaw) agentd.send({ type: "get_available_models", session: selectedRaw })
  }
  function chooseModel(index) {
    var model = modelEntries[index]
    if (!model || !agentd || !selectedRaw) return
    if (!agentd.send({ type: "set_model", session: selectedRaw,
                      provider: String(model.provider), modelId: String(model.id) })) {
      feedbackPill.show("Model change not sent: daemon disconnected")
      return
    }
    modelOpen = false
  }
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
  onRecordedOrchScopeChanged: _recomputeDefault()
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
  readonly property bool askSending: !!(pendingAsk && agentd && agentd._answerIntents[selectedRaw])
  function answerAsk(payload) {
    if (!agentd || !pendingAsk || !agentd.answerAsk(selectedRaw, payload)) return false
    requestFocus()
    return true
  }
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
    return { name: shortName(f.name), rawName: f.name, state: stateLabel(f.status), status: f.status, remote: f.remote === true }
  }

  function fleetActivityColors(sid) {
    agentd ? agentd.curToolGen : 0
    if (!sid) return []
    var names = new Set([sid]), changed = true
    while (changed) {
      changed = false
      for (var i = 0; i < liveSessions.length; i++) {
        var session = liveSessions[i]
        if (session.parent && names.has(session.parent) && !names.has(session.name)) {
          names.add(session.name)
          changed = true
        }
      }
    }
    var colors = []
    for (var i = 0; i < liveSessions.length; i++) {
      var session = liveSessions[i]
      if (!names.has(session.name) || (agentd && agentd.isInterrupting(session.name))) continue
      if (session.status === "streaming" || (agentd && agentd.isBusy(session.name)))
        colors.push(actionGlow(session.name))
    }
    return colors
  }
  readonly property var featuredActivityColors: fleetActivityColors(selectedRaw)
  readonly property bool featuredFleetStreaming: {
    if (!live) return mockFeatured.status === "streaming"
    return featuredActivityColors.length > 0
  }
  // Keep command routing tied to the selected session itself. A busy child colors
  // the shared orb, but Esc must not interrupt an idle parent on the child's behalf.
  readonly property bool featuredStreaming: {
    if (agentd && agentd.pendingGen >= 0 && agentd.isBusy(selectedRaw)) return true
    if (!live) return mockFeatured.status === "streaming"
    for (var i = 0; i < liveSessions.length; i++)
      if (liveSessions[i].name === selectedRaw) return liveSessions[i].status === "streaming"
    return false
  }
  // Depth-ordered roster: children (spawned subagents) nest under their parent
  // session. `parent` is the parent's NAME; roots are top-level sessions.
  readonly property var rosterList: {
    if (!live) return mockRoster
    var all = liveSessions, roots = []
    for (var i = 0; i < all.length; i++) {
      var s = all[i]
      // Only the orchestrator that HOLDS the role belongs in the roster. Handover stands
      // the other host's one down but leaves it registered (David, 2026-08-25).
      if (String(s.profile || "").indexOf("orchestrator") >= 0
          && rail.orchScope.length && String(s.scope || "") !== rail.orchScope) continue
      if (s.parent && all.some(x => x.name === s.parent)) continue
      roots.push(s)
    }
    // Most recently selected first (a child's selection counts for its root), then by
    // name; activity never reorders, so tabs hold still while something streams.
    var rank = {}
    for (var ri = 0; ri < tabRecency.length; ri++) {
      var picked = all.find(x => x.name === tabRecency[ri])
      var root = picked && picked.parent && all.some(x => x.name === picked.parent) ? picked.parent : tabRecency[ri]
      if (rank[root] === undefined) rank[root] = ri
    }
    roots.sort((a, b) => {
      var ra = rank[a.name] === undefined ? Infinity : rank[a.name], rb = rank[b.name] === undefined ? Infinity : rank[b.name]
      return ra !== rb ? ra - rb : a.name < b.name ? -1 : a.name > b.name ? 1 : 0
    })
    var out = []
    for (var r = 0; r < roots.length; r++) {
      var s = roots[r]
      out.push({ name: shortName(s.name), rawName: s.name, idle: stateLabel(s.status),
                 status: s.status, offline: !!s.offline, linked: !!s.parent, cwd: s.cwd || "",
                 hasWorktree: /\.daphen-|\/work\//.test(s.cwd || ""),
                 // A devenv slice belongs to a WORKTREE (<repo>.daphen-<t> locally,
                 // <repo>-<t> on the VM), never to the plain repo root.
                 devenv: /\.daphen-[^/]+$|\/lovable-[^/]+$/.test(s.cwd || ""),
                 remote: rail._isRemote(s.cwd), scope: s.scope || "",
                 profile: s.profile || "", plan: s.plan || "",
                 depth: 0 })
    }
    return out
  }

  // ── new session ─────────────────────────────────────────────────────────────
  // Enter on the roster's last row opens this: pick where it runs, name it, done.
  // local  → an agentd session in the lovable scope at the main checkout
  // remote → `vm-wt <ticket>`, which also makes the worktree + worker session
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
  property var newProjects: []
  Process {
    id: planScan
    running: false
    stdout: SplitParser { onRead: data => {
      var f = String(data).trim()
      if (!f.length) return
      var parts = f.split("/"), slug = parts.pop().replace(/\.md$/, "")
      if (parts.pop() === "projects") rail.newProjects = rail.newProjects.concat([slug])
      else rail.newPlans = rail.newPlans.concat([slug])
    } }
  }
  function scanPlans() {
    newPlans = []
    newProjects = []
    planScan.command = ["sh", "-c",
      "ls -t \"$HOME/personal/notes/storage/plans\"/*.md \"$HOME/personal/notes/storage/projects\"/*.md 2>/dev/null"]
    planScan.running = true
  }
  readonly property var newPlanRows: {
    var f = newFilter.toLowerCase()
    var rows = []
    if (newSpawnPending && !newSpawnPending.rebind)
      for (var p = 0; p < newProjects.length; p++)
        if (!f.length || newProjects[p].toLowerCase().indexOf(f) >= 0) rows.push({ project: newProjects[p] })
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
    if (row.project) {
      var coordinator = newSpawnMsg(newSessionName(row.project))
      coordinator.project = row.project
      agentd.send(coordinator)
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
  Process {
    id: lifecycleProc
    property string action: ""
    property string ticket: ""
    property string session: ""
    stdout: StdioCollector { id: lifecycleOut }
    stderr: StdioCollector { id: lifecycleErr }
    onExited: (code, status) => {
      var label = action === "reap" ? "REAP " : "Turn off "
      var detail = [lifecycleOut.text, lifecycleErr.text].filter(x => String(x || "").trim().length).join("\n").trim()
      if (!detail.length) detail = code === 0 ? "completed" : "no output"
      rail.lifecycleMessage = code === 0 ? label + ticket + ": " + detail
        : label + ticket + " failed (exit " + code + "): " + detail
      feedbackPill.show(rail.lifecycleMessage)
      if (code === 0 && action === "reap" && session === rail.selectedRaw) {
        var fallback = rail.recentFallback(session)
        if (fallback.length) { rail.activeRaw = fallback; rail.defaultRaw = fallback }
      }
    }
  }
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
    var hadPrevious = _prevSelected !== ""
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
    if (hadPrevious) beginSwitchFade()
    else if (selectedRaw) {
      if (agentd) agentd.select(selectedRaw)
      if (_landed) landNvim(selectedRaw)
    }
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
    // Live-follow: land nvim in the session's worktree (+ plan) on open AND on
    // every switch, so the editor always tracks the session you're viewing.
    // First switch retries (nvim's RPC socket may not be up yet); after nvim has
    // answered once, land EXACTLY once per switch — the 3x retry re-ran cd +
    // dashboard three times and the buffer visibly blinked on every session change.
    if (selectedRaw && !_landed) { landTimer.n = 0; landTimer.restart() }
  }

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
    var session = _sessionOf(sid), selected = _sessionOf(selectedRaw)
    return !!session && !!selected && session.id === selected.id
      && nvimSock === _editorSocket(String(session.cwd || ""))
  }
  Connections {
    target: rail.agentd
    function onOpenInNvimRequested(sid, path, line, column) {
      rail.openRequestedFile(sid, path, line, column)
    }
    function onAskAnswered(sid) {
      Qt.callLater(function() {
        if (rail._followsSelected(sid) && rail.focused && !rail.pendingAsk) rail.enterInsert()
      })
    }
    function onSessionSettled(sid) {
      if (rail.agentd) rail.agentd.refreshChanges(sid, rail._sessionCwdOf(sid))
    }
    function onFileActivity(sid, path, line, needleB64, addedLines, editId) {
      var session = rail._sessionOf(sid), cwd = rail._sessionCwdOf(sid), socket = rail._editorSocket(cwd)
      if (!session || !cwd || !socket) return
      var p = String(path)
      if (p.charAt(0) !== "/") p = cwd + "/" + p
      var rows = addedLines === null ? 'nil' : 'vim.json.decode(' + JSON.stringify(JSON.stringify(addedLines)) + ')'
      var lua = "local m=require('cockpit');local recorded=m.record_edit("
              + JSON.stringify(rail.scopeMode) + "," + JSON.stringify(session.id) + "," + JSON.stringify(cwd) + ","
              + JSON.stringify(p) + "," + rows + ",false," + Date.now() + "," + Number(line || 0) + "," + JSON.stringify(editId) + ");"
      if (rail._followsSelected(sid))
        lua += "if recorded then m.follow_remote(" + JSON.stringify(cwd) + "," + JSON.stringify(p) + ","
             + (rail.focused ? 'true' : 'false') + "," + (line > 0 ? String(line) : 'nil') + ","
             + JSON.stringify(String(needleB64 || "")) + "," + rows + ") end;"
      Quickshell.execDetached(["nvim", "--server", socket, "--remote-expr",
        'luaeval(' + JSON.stringify("(function() " + lua + "return '' end)()") + ')'])
    }
    function onEditMarksSnapshot(sid, path, rows, at, line, editId) {
      var session = rail._sessionOf(sid), cwd = rail._sessionCwdOf(sid), socket = rail._editorSocket(cwd)
      if (!session || !cwd || !socket) return
      var p = String(path)
      if (p.charAt(0) !== "/") p = cwd + "/" + p
      var lua = "local m=require('cockpit');local d=m.dashboard_snapshot();local recorded,changed=m.record_edit("
              + JSON.stringify(rail.scopeMode) + "," + JSON.stringify(session.id) + "," + JSON.stringify(cwd) + ","
              + JSON.stringify(p) + ",vim.json.decode(" + JSON.stringify(JSON.stringify(rows)) + "),true,"
              + Number(at || 0) + "," + Number(line || 0) + "," + JSON.stringify(editId) + ");"
      if (rail._followsSelected(sid))
        lua += "if recorded then m.follow_remote(" + JSON.stringify(cwd) + "," + JSON.stringify(p) + ","
             + (rail.focused ? '(changed or (d.active and d.model.identity==' + JSON.stringify(session.id)
                + ' and d.model.cwd==' + JSON.stringify(cwd) + '))' : 'false')
             + "," + Number(line || 1) + ",nil,{}) end;"
      lua += "return ''"
      Quickshell.execDetached(["nvim", "--server", socket, "--remote-expr",
        'luaeval(' + JSON.stringify("(function() " + lua + " end)()") + ')'])
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
  function groupOpen(key, defaultOpen) {
    return expandedGroups[key] !== undefined ? expandedGroups[key] === true : defaultOpen === true
  }
  function toggleGroup(i, defaultOpen) {
    var e = Object.assign({}, expandedGroups)
    e[i] = !groupOpen(i, defaultOpen)
    expandedGroups = e
  }
  function toggleGroupKey(k, defaultOpen) { toggleGroup(k, defaultOpen) }   // string-keyed groups (turn activity)
  // Focus follows whichever field is VISIBLE: with a question up, the composer is
  // hidden and typing belongs to the ask, so `i` must land there instead.
  readonly property bool onSteamDeck: Quickshell.env("COCKPIT_DECK") === "1"
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
    feedDebounce.restart()
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
  function _hoveredWriteRow() {
    var pending = view === "chat" ? [feedView.contentItem] : []
    while (pending.length) {
      var target = pending.pop()
      if (!target || target.visible === false) continue
      if (target.objectName === "writeFileRow" && target.hovered) return target
      for (var child of target.children || []) pending.push(child)
    }
    return null
  }
  function activateCur() {
    var hovered = _hoveredWriteRow()
    if (hovered) { hovered.openFile(); return }
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
      if (it && it.kind === "user" && (it.sender || compactUserMessage(it.text))) {
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
    if (it && (turnActivitySummary(it.items).length || turnThinks(it.items).length)) {
      var key = "turn-" + (it.key || l), groups = Object.assign({}, expandedGroups)
      var open = !groupOpen(key, turnThinks(it.items).some(claudeThought))
      groups[key] = open
      groups[key + "-tools"] = open
      var entries = activityEntries(it.items)
      for (var i = 0; i < entries.length; i++) groups[toolKey(key, entries[i], i)] = open
      expandedGroups = groups
    }
  }
  // Is the cursor'd feed card at least partly in the viewport?
  // j/k only move the cursor. ListView keeps it on screen via its native highlight
  // range (currentIndex + ApplyRange + preferredHighlightBegin/End on feedView) —
  // no contentY math anywhere. For a message taller than the panel, wheel-scroll to
  // read the rest; j/k move card-to-card.
  function moveDown() {
    if (cur < rSize && rosterExpanded) return   // tabs move with h/l
    cur = Math.min(cur + 1, navTotal - 1)
  }
  function moveUp() {
    if (cur < rSize) { if (!rosterExpanded) cur = Math.max(cur - 1, 0); return }
    cur = Math.max(cur - 1, rSize)   // the roster opens only via Ctrl+T/Super+T
  }

  // Blink probes (debug): delegate/dot creations — streaming must not grow these.
  property int probeCardCreates: 0
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
    if (ctrl && e.key === Qt.Key_M) { toggleModelPicker(); return true }
    if (ctrl && e.key === Qt.Key_P) { requestPlanMenu(); return true }
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
  function keyModelPicker(e) {
    if (e.key === Qt.Key_Escape) { modelOpen = false; return true }
    if (e.key === Qt.Key_Down || e.key === Qt.Key_J) {
      modelCur = Math.min(Math.max(0, modelEntries.length - 1), modelCur + 1); return true
    }
    if (e.key === Qt.Key_Up || e.key === Qt.Key_K) {
      modelCur = Math.max(0, modelCur - 1); return true
    }
    if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { chooseModel(modelCur); return true }
    return true
  }

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
      if (e.key === Qt.Key_Y || e.key === Qt.Key_1) { answerAsk({ confirmed: true });  return true }
      if (e.key === Qt.Key_N || e.key === Qt.Key_2) { answerAsk({ confirmed: false }); return true }
    } else if (pm === "select" && pendingAsk.options) {
      var d = e.key - Qt.Key_0
      if (d >= 1 && d <= Math.min(9, pendingAsk.options.length)) { answerAsk({ value: pendingAsk.options[d - 1] }); return true }
    } else if (pm === "input" || pm === "editor") {
      if (e.key === Qt.Key_I) { enterInsert(); return true }
    }
    return false
  }

  function keyNormal(e) {
    if (hintsOpen) {
      if (e.key === Qt.Key_Escape || e.key === Qt.Key_Question || e.key === Qt.Key_Q) hintsOpen = false
      return true
    }
    if (e.key === Qt.Key_Question) { hintsOpen = true; return true }
    var ctrl = (e.modifiers & Qt.ControlModifier)
    var shift = (e.modifiers & Qt.ShiftModifier)
    if (ctrl && (e.key === Qt.Key_Return || e.key === Qt.Key_Enter)) {
      toggleCurBash()
      return true
    }
    // Ctrl+j/Ctrl+k step between feed and composer; the roster opens only via Ctrl+T/Super+T.
    var onTabs = rosterExpanded && cur < rSize
    if (ctrl && e.key === Qt.Key_J) {
      if (onTabs && navTotal > rSize) { rosterOverride = false; cur = navTotal - 1 }
      else enterInsert()
      return true
    }
    if (ctrl && e.key === Qt.Key_K) return true
    if (onTabs && !ctrl && (e.key === Qt.Key_H || e.key === Qt.Key_L)) {
      cur = (cur + (e.key === Qt.Key_L ? 1 : -1) + rSize) % rSize
      return true
    }
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
    case Qt.Key_G:      if (shift) jumpToEnd(); else cur = 0; return true
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
    case Qt.Key_Return: case Qt.Key_Enter:
      if (!_hoveredWriteRow() && startItemMode()) return true
      activateCur(); return true
    case Qt.Key_O:
      activateCur(); return true
    }
    return false
  }

  Keys.onPressed: (e) => {
    _klog(e)
    if (keyGlobal(e)) { e.accepted = true; return }
    if (lifecycleTarget && keyLifecycle(e)) { e.accepted = true; return }
    if (planMenu) {
      if (e.key === Qt.Key_Escape) planMenu = null
      else if (e.key === Qt.Key_J || e.key === Qt.Key_Down) planChoice = Math.min(planMenu.labels.length - 1, planChoice + 1)
      else if (e.key === Qt.Key_K || e.key === Qt.Key_Up) planChoice = Math.max(0, planChoice - 1)
      else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) choosePlan(planChoice)
      e.accepted = true; return
    }
    if (modelOpen && keyModelPicker(e)) { e.accepted = true; return }
    if (fileSelectOpen && keyFileSelection(e)) { e.accepted = true; return }
    if (itemMode && keyItemMode(e)) { e.accepted = true; return }
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
    if (itemMode) exitItemMode()
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
    else if (k === "G") jumpToEnd()
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
  property color railGroundColor: Theme.bgDim
  Rectangle { anchors.fill: parent; color: rail.railGroundColor; z: -1 }
  Canvas {
    id: dotGrid
    anchors.fill: parent
    z: -0.5
    visible: rail.view === "chat"
    readonly property color dotColor: Theme.mode === "light"
      ? Qt.rgba(0.14, 0.14, 0.13, 0.07)
      : Qt.rgba(1, 1, 1, 0.08)
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onVisibleChanged: if (visible) requestPaint()
    onDotColorChanged: if (visible) requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.clearRect(0, 0, width, height)
      ctx.fillStyle = dotGrid.dotColor
      for (var y = 16; y < height; y += 32)
        for (var x = 16; x < width; x += 32) {
          ctx.beginPath()
          ctx.arc(x, y, 1.2, 0, Math.PI * 2)
          ctx.fill()
        }
    }
  }

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
    if (t.kind === "user") return "user|" + String(t.text || "").length + "|" + String(t.deliveryId || "") + "|" + String(t.delivery || "")
    if (t.kind !== "turn") return t.kind + "|" + String(t.text || t.command || "").length
    return "turn|" + _fingerprint(t.items || [])
  }
  // JSON.stringify of whole tool outputs on every sync stalled the GUI thread (and every
  // animation on it) for 100+ ms; long strings are compared by length and samples instead.
  function _fingerprint(v) {
    if (v === null || v === undefined) return "~"
    if (typeof v === "string") {
      var n = v.length
      return n <= 96 ? JSON.stringify(v) : "s" + n + ":" + JSON.stringify(v.slice(0, 24) + v.charAt(n >> 2) + v.charAt(n >> 1) + v.charAt(3 * n >> 2) + v.slice(-24))
    }
    if (typeof v !== "object") return String(v)
    var out = Array.isArray(v) ? "[" : "{"
    if (Array.isArray(v)) for (var i = 0; i < v.length; i++) out += _fingerprint(v[i]) + ","
    else for (var k in v) out += k + ":" + _fingerprint(v[k]) + ","
    return out + "]"
  }
  // Row identity: turns carry a stable key; keyless rows (live pushes, echoes)
  // fall back to kind+text, which never mutates for those kinds.
  function _feedKey(t) {
    if (!t) return ""
    return t.key ? ("k:" + t.key) : (String(t.kind) + ":" + String(t.text || t.command || "").slice(0, 80))
  }
  // Animations share the GUI thread with transcript parsing and row building (~8ms a row), so a
  // switch fetches nothing until the roster collapse ends, then builds newest-first and fades in.
  property int _feedShown: -1
  readonly property int _feedOffset: _feedShown >= 0 ? Math.max(0, groupedFeed.length - _feedShown) : 0
  readonly property bool switching: switchSettle.running || feedFill.running
  readonly property int feedFillStep: 1
  readonly property int feedFillFirst: 2
  // An Animator runs on the render thread, so the feed build and nvim repaint on a switch
  // cannot stall it. It only writes feedView.opacity back when it stops or finishes.
  OpacityAnimator { id: feedFade; target: feedView; duration: Motion.base; easing.type: Easing.OutCubic }
  function fadeFeedIn() {
    if (feedFade.running ? feedFade.to === 1 : feedView.opacity >= 1) return
    feedFade.stop(); feedFade.to = 1; feedFade.duration = 220; feedFade.start()
  }
  Timer {
    id: switchSettle
    interval: Motion.slow + 20
    onTriggered: {
      if (rail.agentd && rail.selectedRaw) rail.agentd.select(rail.selectedRaw)
      if (rail._landed && rail.selectedRaw) rail.landNvim(rail.selectedRaw)
      rail._resyncFeed()
    }
  }
  Timer {
    id: feedFill
    interval: 16; repeat: true
    onTriggered: {
      rail._feedShown += rail.feedFillStep
      if (rail._feedShown >= rail.groupedFeed.length) { rail._feedShown = -1; stop() }
      rail._resyncFeed()
      if (rail._feedShown >= 0 && !feedScroll.following) return
      if (rail._feedShown < 0 && feedScroll.mode === "free" && rail.cur >= rail.rSize)
        feedScroll.cursorMoved(rail.cur - rail.rSize, rail.cur - rail.rSize === rail.groupedFeed.length - 1)
      rail.fadeFeedIn()
    }
  }
  function beginSwitchFade() {
    feedFill.stop(); _feedShown = -1
    feedFade.stop(); feedFade.to = 0; feedFade.duration = Motion.base; feedFade.start()
    switchSettle.restart()
  }
  function syncFeedModel() {
    if (switchSettle.running) return
    var arr = groupedFeed
    if (arr.length > feedFillStep && (_feedReset || (feedModel.count === 0 && _feedShown < 0))) {
      feedFade.stop(); feedView.opacity = 0; _feedShown = feedFillFirst; feedFill.restart()
    } else if (_feedShown < 0) {
      fadeFeedIn()
    }
    if (_feedShown >= 0) arr = arr.slice(Math.max(0, arr.length - _feedShown))
    if (_feedReset) {
      _feedReset = false
      feedModel.clear()
      for (var a = 0; a < arr.length; a++)
        feedModel.append({ d: JSON.parse(JSON.stringify(arr[a])), sig: _turnSig(arr[a]), k: _feedKey(arr[a]) })
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
    function onFeedGenChanged() { if (!feedDebounce.running) feedDebounce.start() }
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

  // Fold the flat feed into cards: each user message stands alone. Agent activity
  // stays in its own card before the prose that follows, so streaming text cannot
  // move already-visible work below the answer. Each prose block closes its card.
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
  readonly property var groupedFeed: taskProjection.rows
  readonly property var taskSegments: taskProjection.segments
  readonly property string activeTask: taskProjection.active
  readonly property var taskProjection: {
    var f = feed, out = [], cur = null, acts = 0, chunked = false
    var segments = [], segment = null, active = ""
    for (var i = 0; i < f.length; i++) {
      var it = f[i]
      if (it.tool === "usage") continue
      if (it.kind === "user") {
        if (cur) { out.push(cur); cur = null; acts = 0 }
        chunked = false
        // A user message whose visible text stripped to nothing (system-reminder
        // only, or a bare sender stamp) rendered as a blank card — skip it.
        var text = String(it.text || ""), sender = it.sender || ""
        if (!sender && text.indexOf("\u21c4 ") === 0) {
          var nl = text.indexOf("\n")
          sender = (nl > 0 ? text.slice(2, nl) : text.slice(2)).trim()
          text = nl > 0 ? text.slice(nl + 1).trim() : ""
        }
        if (!text.trim().length) continue
        out.push({ kind: "user", text: text, mid: it.mid, steered: it.steered === true, sender: sender, deliveryId: it.deliveryId, delivery: it.delivery, key: it.mid || _contentKey("user", it.text) })
      } else if (it.kind === "sys") {
        // Housekeeping (compaction) gets its OWN card so it never colors the
        // neighboring turn's errors.
        if (cur) { out.push(cur); cur = null; acts = 0 }
        chunked = false
        if (!String(it.text || "").trim().length) continue
        if (it.tool === "task") {
          if (it.taskAction === "switch") {
            if (segment) segment.end = out.length - 1
            segment = { key: it.mid, title: it.taskTitle, timestamp: it.timestamp, row: out.length, end: out.length, outcome: "", finishedAt: "", clipped: it.clipped === true }
            segments.push(segment)
            active = it.taskTitle
          } else if (it.taskAction === "finish" && it.taskTitle === active) {
            if (segment) { segment.end = out.length - 1; segment.outcome = it.outcome || ""; segment.finishedAt = it.timestamp }
            segment = null
            active = ""
          }
          continue
        }
        out.push({ kind: "turn", sys: true, items: [it], key: it.mid || _contentKey(it.kind, it.text) })
      } else {
        // An empty assistant text (a turn that produced no prose — aborted mid-turn,
        // or whose only content was a tool call already shown above) rendered as a
        // blank card. Close any open card, but never open one for nothing.
        if (it.kind === "text" && !String(it.text || "").trim().length) {
          if (cur) { out.push(cur); cur = null; acts = 0; chunked = false }
          continue
        }
        if (it.kind === "text" && cur) { out.push(cur); cur = null; acts = 0 }
        if (!cur) { cur = { kind: "turn", items: [], key: it.mid || _contentKey(it.kind, it.text || it.command), contFrom: chunked }; acts = 0 }
        cur.items.push(it)
        if (it.kind === "text") { out.push(cur); cur = null; acts = 0; chunked = false }   // prose is its own card
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
    if (segment) segment.end = out.length - 1
    for (var si = 0; si < segments.length; si++) {
      if (segments[si].clipped && segments[si].end < segments[si].row) {
        segments[si].row = out.length ? Math.min(segments[si].row, out.length - 1) : -1
        segments[si].end = segments[si].row
      }
      segments[si].active = segments[si] === segment
    }
    return { rows: out, segments: segments.filter(s => s.end >= s.row), active: active }
  }

  function jumpToEnd() {
    cur = Math.max(0, navTotal - 1)
    if (view === "chat") feedScroll.toEnd()
  }
  function jumpTask(row) {
    if (row < 0 || row >= groupedFeed.length) return
    exitInsert()
    view = "chat"
    _resyncFeed()
    feedScroll.hold()
    requestFocus()
    cur = rSize + row
    feedScroll.cursorMoved(row, false)
  }
  property var pillTipFor: null
  property string pillTipText: ""
  function showPillTip(item, text) { pillTipText = text; pillTipFor = item }
  function prefillTask() {
    if (composerText.length) { feedbackPill.show("Finish the current draft before changing tasks"); return }
    requestFocus()
    prefillComposer("/task ")
  }
  TaskTimeline {
    id: taskTimeline
    objectName: "sessionTaskTimeline"
    anchors { right: parent.right; rightMargin: 2; top: parent.top; topMargin: 20; bottom: chin.top }
    z: 10
    visible: rail.view === "chat" && rail.taskSegments.length > 0
    segments: rail.taskSegments
    selectedRow: rail.cur - rail.rSize
    onJumpRequested: row => rail.jumpTask(row)
  }

  ColumnLayout {
    anchors { top: parent.top; left: parent.left; right: parent.right; bottom: chin.top }
    anchors.margins: 0
    // Breathing room at the window's top edge — cards used to start at y=0
    // with their first line clipped against the bezel.
    anchors.topMargin: 16
    spacing: 0

    Item {
      id: taskHeader
      readonly property string text: rail.activeTask || rail.selectedPlan
      Layout.fillWidth: true
      Layout.leftMargin: 20
      Layout.rightMargin: 20
      Layout.bottomMargin: visible ? 4 : 0
      visible: rail.view === "chat" && text.length > 0
      implicitHeight: 26
      z: 5
      Rectangle {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: -20; rightMargin: -20 }
        height: parent.height + 16
        color: rail.railGroundColor
      }
      Rectangle {
        anchors { left: parent.left; right: parent.right; top: parent.bottom; leftMargin: -20; rightMargin: -20 }
        height: 18
        gradient: Gradient {
          GradientStop { position: 0; color: rail.railGroundColor }
          GradientStop { position: 1; color: Qt.alpha(rail.railGroundColor, 0) }
        }
      }
      Row {
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
        spacing: 8
        Icon {
          anchors.verticalCenter: parent.verticalCenter
          name: "target"; width: 13; height: 13
          color: chin.muted
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          objectName: "activeTaskLabel"
          width: Math.min(implicitWidth, parent.width - 21)
          text: taskHeader.text
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: taskHeaderHover.hovered ? chin.fg : chin.muted
          font.family: rail.messageFontFamily; font.pixelSize: rail.fsMeta
          HoverHandler { id: taskHeaderHover; enabled: rail.activeTask.length > 0; cursorShape: Qt.PointingHandCursor }
          TapHandler { enabled: rail.activeTask.length > 0; onTapped: rail.prefillTask() }
        }
      }
    }

    Crossfade {
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.leftMargin: 20
      Layout.rightMargin: rail.view === "chat" && rail.taskSegments.length ? taskTimeline.width + 12 : 20
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
      header: Text {
        width: changesView.width
        text: rail.agentd && rail.agentd.changesGen >= 0
          ? String((rail.agentd.changeErrors || {})[rail.selectedRaw] || "") : ""
        height: text.length ? implicitHeight + 12 : 12
        wrapMode: Text.Wrap
        color: Theme.fg_muted
        font.family: Theme.fontFamily
        font.pixelSize: rail.fsMeta
      }
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
      readonly property int shadowGutter: 18
      anchors {
        fill: parent
        leftMargin: -shadowGutter
        rightMargin: -shadowGutter
      }
      enabled: rail.view === "chat"
      clip: false
      displayMarginBeginning: 40
      spacing: 24
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
      // The viewport follows chin.top, preserving the pane's existing animated height.
      // Unclipped delegates may paint beneath the transparent wrapper, while the rounded
      // ContrastCard itself covers them; no gutter or footer geometry has to track it.
      header: Item { width: feedView.width; height: feedView.spacing }
      footer: Item { width: feedView.width; height: 56 }
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
        Component.onCompleted: {
          if (rail._feedShown >= 0) { opacity = 1; introBlur = 0; introY = 0 } else turnIntro.start()
          rail.probeCardCreates++
        }
        ParallelAnimation {
          id: turnIntro
          NumberAnimation { target: turnDel; property: "opacity"; from: 0; to: 1; duration: 150; easing.type: Easing.InOutQuad }
          NumberAnimation { target: turnDel; property: "introY"; from: 4; to: 0; duration: 150; easing.type: Easing.OutCubic }
          NumberAnimation { target: turnDel; property: "introBlur"; from: 0.125; to: 0; duration: 150; easing.type: Easing.InOutQuad }
        }
        property int rowIndex: index + rail._feedOffset
        readonly property real cardHeight: card.height   // for the feedGeom probe
        // Capture the row's turn once: nested Repeaters shadow `model` with their
        // own model property, so model.d is only readable at the delegate root.
        readonly property var turn: model.d
        readonly property bool isUser: turnDel.turn.kind === "user"
        // Assistant blocks sit flush so one reply's rounds read as one flow; cards keep their room.
        readonly property int padY: isNote && !userExpanded ? 8 : (isUser ? 16 : 8)
        readonly property string localDelivery: rail.agentd && turnDel.turn.deliveryId
          ? rail.agentd.localDeliveryFor(rail.selectedRaw, turnDel.turn.deliveryId) : ""
        readonly property bool isHandoff: isUser && !!turnDel.turn.sender
        readonly property bool isSteering: isUser && !isHandoff && turnDel.turn.steered === true
        readonly property bool isNote: isHandoff
        readonly property bool compactUser: isHandoff || (isUser && rail.compactUserMessage(turn.text))
        readonly property string userFoldKey: "user-" + (turn.key || rowIndex)
        readonly property bool userExpanded: compactUser && rail.expandedGroups[userFoldKey] === true
        // Housekeeping (compaction) is the SYSTEM speaking, not the agent.
        readonly property bool isSys: turnDel.turn.sys === true
        readonly property bool cursor: rail.focused && !rail.insert && rail.cur === rail.rSize + rowIndex
        readonly property Item restDot: cursorDot
        Rectangle {
          id: cursorDot
          z: 2
          x: card.x + 10 - width / 2
          y: card.y + turnDel.padY + Math.round(rail.fsBody * 0.7) - height / 2
          width: 8; height: 8; radius: 4
          color: Theme.cursor
          visible: turnDel.cursor && !rail.caretHeld
        }
        readonly property color cardContentColor: Theme.mode === "light" ? "#23272B" : "#FAFAFA"
        readonly property color cardBodyColor: Theme.mode === "light" ? "#343A3F" : "#EDEDED"
        readonly property color cardMutedColor: Theme.mode === "light" ? "#747D84" : "#909090"
        readonly property color userContentColor: cardBodyColor
        readonly property color cardAccent: isUser && !isHandoff ? Theme.orange : (isSys ? rail.silverAccent : rail.lavenderAccent)
        Rectangle {
          id: card
          anchors {
            left: turnDel.isHandoff ? parent.left : undefined
            right: turnDel.isHandoff ? undefined : parent.right
            leftMargin: feedView.shadowGutter - (turnDel.isNote ? 12 : 0)
            rightMargin: feedView.shadowGutter - (turnDel.isUser && !turnDel.isNote ? 0 : 12)
          }
          width: (parent.width - 2 * feedView.shadowGutter) * (turnDel.isUser && !turnDel.isNote ? 0.9 : 1) + (turnDel.isUser && !turnDel.isNote ? 0 : 24)
          implicitHeight: cardCol.implicitHeight + 2 * turnDel.padY
          radius: 18
          color: "transparent"
          border.width: (!turnDel.isUser || turnDel.isNote) && turnDel.cursor ? 1 : 0
          border.color: rail.cardRing
          ContrastCard {
            visible: turnDel.isUser && !turnDel.isNote
            anchors.fill: parent
            cardRadius: card.radius
            elevated: !turnDel.isHandoff
            readonly property bool lightKey: Theme.mode === "light" && !turnDel.isHandoff
            bevelWidth: turnDel.isHandoff || lightKey ? 1 : 2
            faceTop: turnDel.isHandoff ? Theme.surface0 : lightKey ? "#FDFDFD" : rail.userCardTop
            faceUpper: lightKey ? "#FCFCFC" : faceTop
            faceMid: turnDel.isHandoff ? faceTop : lightKey ? "#F8F8F9" : rail.userCardBottom
            faceBottom: lightKey ? "#F3F3F4" : faceMid
            rimTop: turnDel.isHandoff ? outlineColor : (Theme.mode === "light" ? "#FFFFFF" : "#2B2B2B")
            rimBottom: turnDel.isHandoff ? outlineColor : lightKey ? "#F3F3F4" : "#222222"
            outlineColor: turnDel.isHandoff
              ? Qt.rgba(turnDel.cardAccent.r, turnDel.cardAccent.g, turnDel.cardAccent.b, 0.22)
              : (lightKey ? Qt.alpha(Theme.fg, 0.11) : "#282828")
            shadowColor: lightKey ? Qt.rgba(0.12, 0.15, 0.18, 0.07) : "#101010"
            Behavior on rimTop { ColorAnimation { duration: 150; easing.type: Easing.OutCubic } }
            Behavior on outlineColor { ColorAnimation { duration: 150; easing.type: Easing.OutCubic } }
          }
          LightKey {
            anchors.fill: parent
            visible: turnDel.isUser && !turnDel.isNote && !turnDel.isHandoff && Theme.mode === "light"
            radius: card.radius
            outline: Qt.alpha(Theme.fg, 0.16)
          }
          Rectangle {
            anchors.fill: parent
            radius: card.radius
            color: turnDel.isHandoff ? Qt.rgba(turnDel.cardAccent.r, turnDel.cardAccent.g, turnDel.cardAccent.b, 0.08) : "transparent"
            visible: turnDel.isUser && !turnDel.isNote
            border.width: 1
            border.color: rail.cardRing
            opacity: turnDel.cursor ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
          }
          TapHandler {
            onTapped: eventPoint => {
              const disclosure = turnDel.isHandoff ? noteDisclosure : fullMessageButton
              const point = disclosure.mapFromItem(card, eventPoint.position.x, eventPoint.position.y)
              if (disclosure.visible && disclosure.contains(point)) return
              var pending = [card]
              while (pending.length) {
                var item = pending.pop()
                if (!item || item.visible === false) continue
                if (item.objectName === "writeFileRow" && item.contains(item.mapFromItem(card, eventPoint.position.x, eventPoint.position.y))) return
                for (var child of item.children || []) pending.push(child)
              }
              rail.selectAt(rail.rSize + turnDel.rowIndex)
            }
          }

          Column {
            id: cardCol
            anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: turnDel.isUser ? 24 : 36; rightMargin: turnDel.isUser ? 24 : 36; topMargin: turnDel.padY }
            spacing: turnDel.isNote && !turnDel.userExpanded ? 8 : 16

            // Turn header — the Nucleo glyph is the ONLY colored signifier;
            // the label stays neutral and a touch bigger than the body text.
            Item {
              visible: turnDel.isUser
              width: cardCol.width
              height: userHeader.height
              Row {
                id: userHeader
                spacing: 8
                Icon {
                  name: turnDel.isUser && !turnDel.isHandoff ? "paper-plane-2" : "sparkle-3"
                  variantSize: turnDel.isUser && !turnDel.isHandoff ? 12 : 0
                  width: 16; height: 16; anchors.verticalCenter: parent.verticalCenter
                  color: turnDel.cardAccent
                }
                Text {
                  text: turnDel.turn.sender ? "From " + turnDel.turn.sender.replace(/\s+\(user-approved\)$/, "") : "You"
                  width: turnDel.isHandoff ? Math.min(implicitWidth, Math.max(0, cardCol.width - noteDisclosure.width - 32 - (steerBadge.visible ? steerBadge.width + 8 : 0))) : implicitWidth
                  elide: Text.ElideRight
                  color: turnDel.cardContentColor
                  font.family: rail.labelFontFamily; font.styleName: rail.labelFontStyle(600)
                  font.pixelSize: turnDel.isNote ? rail.fsMeta : rail.fsName; font.weight: 600
                  anchors.verticalCenter: parent.verticalCenter
                }
                PrimaryButton {
                  id: noteDisclosure
                  visible: turnDel.isHandoff
                  implicitHeight: 22
                  implicitWidth: noteLabel.width + 24
                  anchors.verticalCenter: parent.verticalCenter
                  primary: false
                  text: turnDel.userExpanded ? "Collapse" : "Read full message"
                  onClicked: rail.clickAt(rail.rSize + turnDel.rowIndex)
                  TextMetrics {
                    id: noteLabel
                    text: noteDisclosure.text
                    font { family: Theme.fontFamily; pixelSize: noteDisclosure.fontPixelSize; weight: 500 }
                  }
                }
                // A steer redirected a LIVE turn — visibly different from a normal
                // prompt, so "why did it abort" has its answer in the header.
                Rectangle {
                  id: steerBadge
                  visible: turnDel.isSteering || (turnDel.isHandoff && turnDel.turn.steered === true)
                  implicitWidth: steerCap.implicitWidth + 12
                  implicitHeight: 17; radius: 8.5
                  color: "transparent"
                  border.width: 1; border.color: Theme.orange
                  anchors.verticalCenter: parent.verticalCenter
                  Text {
                    id: steerCap; anchors.centerIn: parent
                    text: "steer"
                    color: Theme.orange
                    font.family: rail.labelFontFamily; font.styleName: rail.labelFontStyle(700)
                    font.pixelSize: rail.fsMeta - 3; font.bold: true
                  }
                }
              }
              Item {
                objectName: "delivery-status"
                readonly property string delivery: turnDel.localDelivery
                visible: delivery === "pending" || delivery === "accepted"
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                width: 14; height: 14
                Spinner { anchors.centerIn: parent; visible: parent.delivery === "pending"; running: visible; color: turnDel.cardMutedColor; dotSize: 1.6 }
                Icon { anchors.fill: parent; visible: parent.delivery === "accepted"; name: "check"; color: turnDel.cardMutedColor }
              }
            }

            Flow {
              visible: turnDel.localDelivery === "failed"
              width: cardCol.width
              spacing: 8
              Text {
                text: "Not delivered"
                color: Theme.orange
                font.family: rail.messageFontFamily; font.pixelSize: rail.fsMeta
                height: 24; verticalAlignment: Text.AlignVCenter
              }
              PrimaryButton {
                visible: turnDel.localDelivery === "failed"
                text: "Resend"; primary: false; implicitHeight: 24
                onClicked: {
                  rail.agentd.resendLocalEcho(rail.selectedRaw, turnDel.turn.deliveryId)
                  rail.feedTick++; rail._resyncFeed()
                }
              }
              PrimaryButton {
                text: "Discard"; primary: false; implicitHeight: 24
                onClicked: {
                  rail.agentd.dismissLocalEcho(rail.selectedRaw, turnDel.turn.deliveryId)
                  rail.feedTick++; rail._resyncFeed()
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
                running: visible; color: turnDel.cardMutedColor; dotSize: 1.6
              }
              Text {
                text: rail.featuredStreaming ? "thinking — nothing streamed yet"
                                             : "· turn ended without visible output"
                color: turnDel.cardMutedColor
                font.family: rail.messageFontFamily; font.pixelSize: rail.fsMeta; font.weight: rail.messageMetaWeight
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            PrimaryButton {
              id: fullMessageButton
              visible: turnDel.compactUser && !turnDel.isHandoff
              width: Math.min(cardCol.width, implicitWidth)
              implicitHeight: 28
              radius: Theme.radiusSm
              primary: false
              text: turnDel.userExpanded ? "Hide full message" : "Show full message"
              iconName: turnDel.userExpanded ? "chevron-down" : "chevron-right"
              onClicked: rail.clickAt(rail.rSize + turnDel.rowIndex)
            }

            Text {
              visible: turnDel.compactUser && !turnDel.userExpanded
              width: cardCol.width
              text: String(turnDel.turn.text || "").replace(/\s+/g, " ").trim()
              textFormat: Text.PlainText
              color: turnDel.userContentColor
              font.family: rail.messageFontFamily; font.pixelSize: rail.fsBody; font.weight: rail.messageBodyWeight
              lineHeightMode: Text.FixedHeight; lineHeight: rail.fsBody * 1.5
              wrapMode: Text.Wrap; maximumLineCount: turnDel.isHandoff ? 2 : 3; elide: Text.ElideRight
            }

            Loader {
              active: turnDel.isUser && (!turnDel.compactUser || turnDel.userExpanded)
              visible: active
              width: cardCol.width
              sourceComponent: rail.hasInlineBadges(sourceText) ? inlineAttachmentContent : markdownContent
              property string sourceText: turnDel.isUser ? String(turnDel.turn.text || "") : ""
              property int sourceEntry: 0
              property int sourceOffset: 0
              property int rowIndex: turnDel.rowIndex
              property color bodyColor: turnDel.userContentColor
              property bool agentAuthored: false
            }

            // Status markers (compaction, retries) — inline, muted. They carry no
            // activity counts, so without this they rendered as an EMPTY agent card.
            Repeater {
              model: turnDel.isUser ? 0 : rail.turnInfos(turnDel.turn.items).length
              Text {
                x: -12; width: cardCol.width + 24
                text: rail.plainToolText(rail.turnInfos(turnDel.turn.items)[index] || "").replace(/^🔌\s*/, "")
                textFormat: Text.PlainText
                color: turnDel.cardMutedColor
                font.family: rail.messageFontFamily; font.pixelSize: rail.fsMeta; font.weight: rail.messageMetaWeight
              }
            }

            Repeater {
              model: turnDel.isUser ? [] : (turnDel.turn.items || []).filter(item => item.kind === "cmd" && item.tool === "error")
              RowLayout {
                x: -12; width: cardCol.width + 24
                spacing: 8
                Icon { name: "triangle-warning"; width: 16; height: 16; color: Theme.red; Layout.minimumWidth: 16; Layout.maximumWidth: 16; Layout.alignment: Qt.AlignTop }
                Text {
                  Layout.fillWidth: true
                  text: rail.plainToolText(modelData.text).replace(/^\s*[⚠✗⨯⏹]\s*/, "")
                  textFormat: Text.PlainText
                  color: Theme.red
                  font.family: rail.messageFontFamily
                  font.pixelSize: rail.fsBody
                  font.weight: rail.messageBodyWeight
                  wrapMode: Text.Wrap
                }
              }
            }

            // Agent prose — the headline answer (each text block).
            Repeater {
              id: proseRep
              readonly property var items: turnDel.isUser ? [] : rail.turnProse(turnDel.turn.items)
              model: CountModel { size: proseRep.items.length }
              Loader {
                x: -12; width: cardCol.width + 24
                property var entry: proseRep.items[index] || ({})
                property int entryIndex: index
                property int rowIndex: turnDel.rowIndex
                property color bodyColor: turnDel.cardBodyColor
                property color mutedColor: turnDel.cardMutedColor
                sourceComponent: proseRow
              }
            }

            Repeater {
              model: turnDel.isUser ? [] : rail.turnSys(turnDel.turn.items)
              Text {
                x: -12; width: cardCol.width + 24
                text: rail.plainToolText(modelData.text || "").replace(/^🔌\s*/, "")
                textFormat: Text.PlainText
                color: turnDel.cardMutedColor
                font.family: rail.messageFontFamily
                font.pixelSize: rail.fsMeta
                font.weight: rail.messageMetaWeight
                wrapMode: Text.WordWrap
              }
            }

            Repeater {
              model: turnDel.isUser ? [] : rail.turnUserBash(turnDel.turn.items)
              Loader {
                x: -24; width: cardCol.width + 48
                property var entry: modelData
                sourceComponent: userBashRow
              }
            }

            Loader {
              active: !turnDel.isUser && (rail.turnActivitySummary(turnDel.turn.items).length > 0 || rail.turnThinks(turnDel.turn.items).length > 0)
              visible: active
              x: -24; width: cardCol.width + 48
              sourceComponent: activityRow
              property var items: turnDel.isUser ? [] : turnDel.turn.items
              // Keyed on the row's stable identity, not its index: a group you expanded
              // otherwise collapsed (and its neighbour opened) as the window slid.
              property string ekey: "turn-" + (turnDel.turn.key || turnDel.rowIndex)
              readonly property bool defaultReasoning: rail.turnThinks(items).some(rail.claudeThought)
              property bool expanded: rail.groupOpen(ekey, defaultReasoning)
              property color textColor: turnDel.cardBodyColor
              property color mutedColor: turnDel.cardMutedColor
            }

            // Only prose needs a continuation marker; tool-only chunks have their own summary.
            Text {
              visible: !turnDel.isUser && turnDel.turn.cont === true && rail.turnProse(turnDel.turn.items).length > 0
              text: "⋯ continues"
              color: turnDel.cardMutedColor
              font.family: rail.messageFontFamily; font.pixelSize: rail.fsMeta; font.weight: rail.messageMetaWeight
            }
          }
        }
      }
    }
    }

  }



  // Chin: the bottom SHEET — roster + composer in one container, anchored to the
  // rail bottom. The feed continues behind it; this later sibling paints above the
  // cards, while the feed footer keeps the final row reachable above the pane.
  readonly property alias palette: chin
  Rectangle {
    id: chin
    readonly property bool lightMode: Theme.mode === "light"
    readonly property color fg: lightMode ? "#23272B" : "#FAFAFA"
    readonly property color muted: lightMode ? "#747D84" : "#858585"
    readonly property color baseSurface: lightMode ? "#F7F9FA" : "#141414"
    readonly property color raisedSurface: lightMode ? "#EEF2F5" : "#141414"
    readonly property color cardSurface: lightMode ? "#F4F6F8" : "#141414"
    readonly property color hairline: lightMode ? Qt.rgba(0.14, 0.14, 0.13, 0.16) : Qt.rgba(1, 1, 1, 0.14)
    readonly property color softHairline: lightMode ? Qt.rgba(0.14, 0.14, 0.13, 0.11) : Qt.rgba(1, 1, 1, 0.10)
    readonly property color itemCursor: lightMode ? Theme.itemCursor : Qt.rgba(1, 1, 1, 0.14)
    readonly property color itemSelected: lightMode ? Theme.itemSelected : Qt.rgba(1, 1, 1, 0.10)
    readonly property color itemHover: lightMode ? Theme.itemHover : Qt.rgba(1, 1, 1, 0.07)
    readonly property color decisionOrange: lightMode ? "#D75A13" : "#FF570D"
    readonly property color decisionGreen: lightMode ? "#4B8069" : "#97B5A6"
    readonly property color decisionRed: lightMode ? "#B94545" : "#FF7B72"
    component ChinKeyCap: KeyCap {
      color: chin.lightMode ? "#F7F9FA" : "#2D2D2D"
      border.color: chin.lightMode ? "#C9D1D8" : "#4A4A4A"
      textColor: chin.lightMode ? "#4F5961" : "#B5B9BB"
    }
    component ChinCapLabel: CapLabel { color: chin.lightMode ? "#747D84" : "#9AA2A7" }
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
    z: 5
    // Inset from the sides so the sheet's own hairline never doubles up against the
    // term/rail divider; still bleeds one radius below the window for a square bottom.
    anchors.leftMargin: 18; anchors.rightMargin: 18
    anchors.bottomMargin: -radius
    radius: 20 + 8
    color: "transparent"
    // 108 = composer + hints + padding, stable across the insert toggle. A pending
    // ask_user expands the chin to hold it, so the question takes over the input
    // instead of floating over the feed — animated so the jump is legible.
    // Height follows the content. The chin is anchored to the BOTTOM, so whatever it
    // contains — composer, ask card, new-session panel — it grows upward from a fixed
    // bottom edge with no arithmetic. (This used to be a hardcoded 108 plus per-panel
    // fudge factors, which is how the new-session card ended up overflowing.)
    clip: false
    height: chinCol.implicitHeight + 32 + radius   // 15 above the tabs (+2 for their -2 offset) and 15 below the input

    ContrastCard {
      anchors.fill: parent
      cardRadius: chin.radius
      faceTop: Theme.mode === "light" ? rail.userCardBottom : rail.userCardTop
      faceUpper: faceTop
      faceMid: rail.userCardBottom
      faceBottom: faceMid
    }
    LightKey {
      anchors.fill: parent
      visible: Theme.mode === "light"
      radius: chin.radius
      outline: Qt.alpha(Theme.fg, 0.16)
    }

    ColumnLayout {
      id: chinCol
      objectName: "chinContent"
      // Bottom-anchored so the composer + hints stay put and the roster grows UPWARD
      // when it expands (the sheet's top edge rises; the input never moves).
      // 12 visible: with the 16px hint row the old 6px left the caps flush with
      // the window edge; 12 recenters the band on the (now 36px) nvim chin.
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 20; rightMargin: 20; bottomMargin: 15 + chin.radius }
      spacing: 10


      Item {
        id: attachments
        objectName: "composerAttachments"
        Layout.fillWidth: true
        Layout.maximumWidth: chinCol.width
        Layout.topMargin: -chinCol.spacing
        readonly property bool populated: rail.codeAttachments.length > 0 || rail.planDraft !== null
        visible: populated || height > 0.5
        implicitHeight: populated ? attachmentFlow.implicitHeight + chinCol.spacing : 0
        clip: true
        Behavior on implicitHeight {
          NumberAnimation { duration: Motion.slow; easing.type: Easing.InOutQuad }
        }
        Flow {
          id: attachmentFlow
          y: chinCol.spacing; width: parent.width; spacing: 6
          Rectangle {
            visible: rail.planDraft !== null
            width: planDraftLabel.implicitWidth + 24; height: 28; radius: 14
            color: chin.raisedSurface; border.color: chin.softHairline
            Text { id: planDraftLabel; anchors.centerIn: parent; text: (rail.planDraft ? rail.planDraft.title : "") + " ×"; color: chin.fg; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta - 1 }
            TapHandler { onTapped: rail.removePlanDraft() }
          }
          Repeater {
            model: rail.codeAttachments
            Rectangle {
              required property var modelData
              required property int index
              objectName: "codeAttachment-" + index
              width: Math.min(codeLabel.implicitWidth + codeRange.implicitWidth + 74, attachmentFlow.width)
              height: 28; radius: height / 2
              color: chin.raisedSurface; border.color: Qt.alpha(rail.goldAccent, 0.38)
              Icon {
                id: codeIcon
                anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                name: "file-content--outline--18"; width: 14; height: 14; color: rail.goldAccent
              }
              Text {
                id: codeLabel
                anchors { left: codeIcon.right; leftMargin: 6; right: codeRange.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
                text: String(modelData.path).split("/").pop()
                textFormat: Text.PlainText; elide: Text.ElideMiddle
                color: chin.fg; font { family: Theme.fontFamily; pixelSize: rail.fsMeta - 1; weight: 500 }
              }
              Text {
                id: codeRange
                anchors { right: removeCodeButton.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
                text: ":" + modelData.l1 + (modelData.l1 === modelData.l2 ? "" : "–" + modelData.l2)
                color: Qt.alpha(rail.goldAccent, 0.72); font { family: Theme.fontFamily; pixelSize: rail.fsMeta - 2 }
              }
              Item {
                id: removeCodeButton
                objectName: "removeCodeAttachment"
                anchors { right: parent.right; rightMargin: 4; verticalCenter: parent.verticalCenter }
                width: 28; height: 28
                Rectangle { anchors.centerIn: parent; width: 20; height: 20; radius: 10; color: closeHover.hovered ? Theme.hover : "transparent" }
                Icon { anchors.centerIn: parent; name: "xmark--glyph--12"; width: 10; height: 10; color: closeHover.hovered ? chin.fg : chin.muted }
                HoverHandler { id: closeHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: rail.removeCode(index) }
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
        color: chin.baseSurface
        border.width: 1; border.color: chin.hairline
        RowLayout {
          anchors { left: parent.left; right: parent.right; leftMargin: 10; rightMargin: 10
                    verticalCenter: parent.verticalCenter }
          spacing: 8
          Icon {
            name: "alarm-clock--outline--18"
            width: 13; height: 13; color: chin.muted
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
            color: chin.muted
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
      color: chin.cardSurface
      border.width: 1
      border.color: chin.hairline
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
            color: chin.muted
          }
          Text {
            Layout.fillWidth: true
            text: "stopped on a question — send a prompt with your answer to continue"
            color: chin.muted
            font.pixelSize: rail.fsMeta
            font.family: Theme.fontFamily
            elide: Text.ElideRight
          }
          ChinKeyCap { small: true; text: "C-d" }
          ChinCapLabel { text: "dismiss" }
        }
        Text {
          Layout.fillWidth: true
          text: rail.staleAsk ? rail.staleAsk.title : ""
          color: chin.fg
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
    // input/editor → i to type. Answered via keys, clickable options, or the composer.
    Rectangle {
      id: askCard
      readonly property var ask: rail.pendingAsk
      readonly property var userBash: rail.pendingUserBash
      readonly property string prompt: ask ? String(ask.message || ask.placeholder || "") : ""
      readonly property bool largeTargets: width < 480
      visible: ask !== null && rail.view === "chat"
      Layout.fillWidth: true
      implicitHeight: askCol.implicitHeight + 28
      radius: 14
      color: chin.cardSurface
      border.width: 1
      border.color: chin.decisionOrange
      z: 12

      Rectangle {   // left attention accent
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom; topMargin: 12; bottomMargin: 12 }
        width: 2; radius: 1; color: chin.decisionOrange
      }

      Column {
        id: askCol
        anchors { left: parent.left; right: parent.right; top: parent.top
                  leftMargin: 18; rightMargin: 16; topMargin: 14 }
        spacing: 9

        Row {
          spacing: 8
          Spinner { visible: rail.askSending; running: visible; color: chin.decisionOrange; dotSize: 1.5; anchors.verticalCenter: parent.verticalCenter }
          Text {
            objectName: "question-reply-status"
            text: rail.askSending ? "Sending reply…" : askCard.userBash ? "run as you" : "needs your input"
            color: chin.decisionOrange; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta; font.bold: true
          }
        }
        Text {
          visible: text.length > 0; width: parent.width; wrapMode: Text.Wrap
          text: askCard.userBash ? ("! " + String(askCard.userBash.command || ""))
                                 : (askCard.ask ? (askCard.ask.title || "") : "")
          color: chin.fg; font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
        }
        Text {
          visible: text.length > 0; width: parent.width; wrapMode: Text.Wrap
          text: askCard.userBash
              ? (String(askCard.userBash.reason || "") + "\n" + String(askCard.userBash.host || "") + ":" + String(askCard.userBash.cwd || ""))
              : rail.colorizeLinks(askCard.prompt)
          textFormat: askCard.userBash ? Text.PlainText : Text.MarkdownText
          color: chin.muted; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
          onLinkActivated: (url) => Quickshell.execDetached(["xdg-open", url])
        }
        // An ask with NO title and NO message is unanswerable as posed — say so
        // instead of presenting a bare box (the payload is journaled by agentd).
        Text {
          visible: askCard.ask && !askCard.userBash
                   && !String(askCard.ask.title || "").length
                   && !askCard.prompt.length
          width: parent.width; wrapMode: Text.Wrap
          text: rail.onSteamDeck
              ? "the agent asked for input without saying why — press B to cancel the question"
              : "the agent asked for input without saying why — press t to make it explain, or esc to cancel the question"
          color: chin.muted; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
          font.italic: true
        }

        // select → one keycap-numbered row per option
        Column {
          width: askCol.width
          spacing: 6
          enabled: !rail.askSending; opacity: enabled ? 1 : 0.5
          visible: askCard.ask && askCard.ask.method === "select"
          Repeater {
            model: (askCard.ask && askCard.ask.method === "select") ? askCard.ask.options : []
            Rectangle {
              id: optionRow
              width: askCol.width
              implicitHeight: Math.max(askCard.largeTargets ? 48 : 30, optionText.implicitHeight + (askCard.largeTargets ? 16 : 8))
              radius: 8
              color: optionHover.hovered ? chin.itemHover : "transparent"
              border.width: 1; border.color: chin.softHairline
              Row {
                anchors { fill: parent; leftMargin: 6; rightMargin: 6 }
                spacing: 9
                ChinKeyCap { id: optionCap; text: rail.onSteamDeck && index < 4 ? "RT+" + ["A", "B", "X", "Y"][index] : String(index + 1); anchors.verticalCenter: parent.verticalCenter }
                Text {
                  id: optionText
                  text: modelData; color: chin.fg; width: parent.width - optionCap.width - 9; wrapMode: Text.Wrap
                  font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
              HoverHandler { id: optionHover; cursorShape: Qt.PointingHandCursor }
              TapHandler { onTapped: rail.answerAsk({ value: modelData }) }
            }
          }
        }

        // confirm → y / n
        Flow {
          width: askCol.width
          spacing: 10
          enabled: !rail.askSending; opacity: enabled ? 1 : 0.5
          visible: askCard.ask && askCard.ask.method === "confirm"
          Row { width: askCard.largeTargets ? (askCol.width - 10) / 2 : implicitWidth; height: askCard.largeTargets ? 48 : implicitHeight
            spacing: 8; ChinKeyCap { text: rail.onSteamDeck ? "RT+A" : "y"; anchors.verticalCenter: parent.verticalCenter }
            Text { text: askCard.userBash ? "Run" : "yes"; color: chin.decisionGreen; font.family: Theme.fontFamily; font.pixelSize: rail.fsBody; anchors.verticalCenter: parent.verticalCenter }
            TapHandler { onTapped: rail.answerAsk({ confirmed: true }) } }
          Row { width: askCard.largeTargets ? (askCol.width - 10) / 2 : implicitWidth; height: askCard.largeTargets ? 48 : implicitHeight
            spacing: 8; ChinKeyCap { text: rail.onSteamDeck ? "RT+B" : "n"; anchors.verticalCenter: parent.verticalCenter }
            Text { text: askCard.userBash ? "Decline" : "no"; color: chin.decisionRed; font.family: Theme.fontFamily; font.pixelSize: rail.fsBody; anchors.verticalCenter: parent.verticalCenter }
            TapHandler { onTapped: rail.answerAsk({ confirmed: false }) } }
          // Neither yes nor no: release the agent from the question and open the composer,
          // for the common case where the question itself is the thing worth discussing.
          Row { visible: !askCard.userBash; width: askCard.largeTargets ? askCol.width : implicitWidth
            height: askCard.largeTargets ? 48 : implicitHeight; spacing: 8
            ChinKeyCap { text: "t"; anchors.verticalCenter: parent.verticalCenter }
            Text { text: "talk about this"; color: chin.fg; font.family: Theme.fontFamily; font.pixelSize: rail.fsBody; anchors.verticalCenter: parent.verticalCenter }
            TapHandler { onTapped: { rail.answerAsk({ cancelled: true, discussing: true }); Qt.callLater(rail.enterInsert) } } }
        }

        // input/editor → answer HERE, in the card, not in the composer below
        Rectangle {
          width: askCol.width
          visible: askCard.ask && (askCard.ask.method === "input" || askCard.ask.method === "editor")
          implicitHeight: 44
          height: implicitHeight
          radius: 10
          color: chin.baseSurface
          border.color: rail.insert ? chin.decisionOrange : chin.hairline
          border.width: 1
          RowLayout {
            anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
            spacing: 8
            Icon { name: "chevron-right"; width: 14; height: 14; color: chin.decisionOrange }
            TextInput {
              id: askInput
              readOnly: rail.askSending
              Layout.fillWidth: true
              color: chin.fg
              font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
              clip: true
              verticalAlignment: TextInput.AlignVCenter
              cursorDelegate: Rectangle { width: 2; radius: 1; color: Theme.cursor; opacity: askInput.cursorVisible ? 1 : 0 }
              onAccepted: {
                if (!text.trim().length || !rail.answerAsk({ value: text })) return
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
              color: chin.muted
              font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
            }
          }
        }

        Text {
          width: askCol.width; wrapMode: Text.Wrap
          readonly property bool hasUrl: askCard.ask && rail.firstUrl(String(askCard.ask.title || "") + "\n" + askCard.prompt).length > 0
          text: rail.askSending ? "Waiting for the agent to confirm receipt…" : (hasUrl ? (rail.onSteamDeck ? "tap link · " : "ctrl+o opens link · ") : "") + (rail.askDeferred ? "finish typing · esc to answer"
              : rail.onSteamDeck && askCard.ask && askCard.ask.method === "select"
                ? "hold RT + A/B/X/Y for options 1–4 · tap any option · B cancels"
              : rail.onSteamDeck && askCard.ask && askCard.ask.method === "confirm"
                ? "hold RT + A for yes · RT + B for no · B cancels"
              : rail.onSteamDeck ? "press X for keyboard · B cancels"
              : askCard.userBash ? "click Run · y runs · n declines · esc cancels"
              : (askCard.ask && askCard.ask.method === "select")
                ? "click an option or press a number · t to talk · esc cancels" : "t to talk · esc cancels")
          color: chin.muted; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
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
        color: chin.cardSurface
        border.width: 1
        border.color: rail.lavenderAccent
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
            color: rail.lavenderAccent
            font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta; font.bold: true
          }
          // Pane 1 — folders (recent-first, fuzzy-filtered by typing).
          Text {
            visible: rail.newMode !== "remote" && rail.newMode !== "plan-new" && (!rail.newFolder.length || !!rail.newSpawnPending) && rail.newFilter.length > 0
            text: "filter: " + rail.newFilter
            color: chin.muted; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
          }
          Column {
            width: newCol.width
            visible: rail.newMode !== "remote" && !rail.newFolder.length
            spacing: 2
            Repeater {
              model: rail.newFolderRows.slice(rail.newWinStart, rail.newWinStart + 12)
              Rectangle {
                width: parent.width; implicitHeight: 30; radius: 8
                color: (rail.newWinStart + index) === rail.newCur ? chin.itemCursor : "transparent"
                Row {
                  anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                  spacing: 8
                  Text { text: modelData.name; color: chin.fg
                         font.family: Theme.fontFamily; font.pixelSize: rail.fsBody }
                  Text {
                    // how many sessions already live there — the resume signal
                    text: { rail.agentd ? rail.agentd.sessions.length : 0
                            var c = rail.sessionsIn(modelData.path).length
                            return c > 0 ? c + " session" + (c > 1 ? "s" : "") : "" }
                    color: chin.muted; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
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
                color: index === rail.newCur ? chin.itemCursor : "transparent"
                Row {
                  anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                  spacing: 8
                  Text {
                    text: modelData.kind === "new"   ? "+ new session (" + rail.newSessionName(rail.newFolder) + ")"
                        : modelData.kind === "adopt" ? "adopt orphaned transcript · " + (modelData.stamp || modelData.id.slice(0, 19))
                        : (modelData.sess.name + "  ·  " + (modelData.sess.status || "?"))
                    color: modelData.kind === "new" ? rail.lavenderAccent
                         : modelData.kind === "adopt" ? chin.muted : chin.fg
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
                color: (rail.newPlanWinStart + index) === rail.newCur ? chin.itemCursor : "transparent"
                Row {
                  anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                  spacing: 8
                  Text {
                    text: modelData.project ? "project · " + modelData.project
                        : modelData.newPlan ? "new plan…"
                        : modelData.none ? "no plan" : modelData.slug
                    color: modelData.none ? chin.muted
                         : modelData.project ? rail.skyAccent
                         : modelData.newPlan ? rail.lavenderAccent : chin.fg
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
            color: chin.baseSurface
            border.color: rail.insert ? rail.activeRing : chin.hairline
            border.width: 2
            Behavior on border.color { ColorAnimation { duration: 650; easing.type: Easing.InOutQuad } }
            RowLayout {
              anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
              spacing: 8
              Icon {
                name: "chevron-right"; width: 14; height: 14
                color: rail.insert ? rail.activeRing : chin.hairline
                Behavior on color { ColorAnimation { duration: 650; easing.type: Easing.InOutQuad } }
              }
              TextInput {
                id: newInput
                Layout.fillWidth: true
                color: chin.fg
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
            color: chin.muted; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
          }
        }
      }

      Item {
        id: composerContext
        objectName: "composerContext"
        Layout.fillWidth: true
        Layout.topMargin: -2
        Layout.bottomMargin: 2
        Layout.minimumWidth: 0
        visible: (!rail.pendingAsk || rail.askDeferred) && !rail.newOpen
        implicitHeight: 28
        readonly property real rowHeight: 28
        InlineSessions {
          id: inlineSessions
          anchors { left: parent.left; right: cornerControls.left; rightMargin: 10; top: parent.top }
        }
        Row {
          id: cornerControls
          anchors { right: parent.right; top: parent.top; topMargin: Math.max(0, (composerContext.rowHeight - height) / 2) }
          spacing: 2
            Rectangle {
              id: modelPill
              anchors.verticalCenter: parent.verticalCenter
              visible: rail.selectedModelLabel.length > 0
              readonly property color tint: chin.muted
              readonly property bool expanded: rail.onSteamDeck || modelHover.hovered || rail.modelOpen
              implicitWidth: expanded ? modelRow.implicitWidth + 12 : 30
              Behavior on implicitWidth { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
              clip: true
              implicitHeight: 22
              radius: 11
              color: modelHover.hovered || rail.modelOpen ? chin.itemHover : Qt.alpha(chin.itemHover, 0)
              border.width: 1
              border.color: "transparent"
              Behavior on color { ColorAnimation { duration: 140 } }
              Behavior on border.color { ColorAnimation { duration: 140 } }
              Row {
                id: modelRow
                anchors { left: parent.left; leftMargin: 6; verticalCenter: parent.verticalCenter }
                spacing: 5
                Icon {
                  anchors.verticalCenter: parent.verticalCenter
                  width: 16; height: 16
                  name: "bolt-lightning"
                  color: modelPill.tint
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: rail.selectedModelLabel
                  visible: modelPill.expanded
                  color: modelPill.tint
                  font { family: Theme.fontFamily; pixelSize: rail.fsMeta - 2; weight: 650 }
                }
              }
              HoverHandler { id: modelHover }
              TapHandler { onTapped: rail.toggleModelPicker() }
            }
            Rectangle {
              id: goalPill
              anchors.verticalCenter: parent.verticalCenter
              visible: !rail.onSteamDeck && (rail.selectedGoal.length > 0 || rail.selectedIsOrchestrator)
              readonly property bool armed: rail.selectedGoal.length > 0
              readonly property color tint: armed ? Theme.green : Theme.orange
              readonly property bool expanded: goalHover.hovered
              implicitWidth: expanded ? goalRow.implicitWidth + 12 : 30
              implicitHeight: 22
              radius: 11
              color: expanded ? chin.itemHover : Qt.alpha(chin.itemHover, 0)
              border.width: 1
              border.color: "transparent"
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
            Rectangle {
              id: scopeSwitch
              anchors.verticalCenter: parent.verticalCenter
              readonly property color tint: rail.scopeMode === "work" ? rail.skyAccent : Theme.orange
              readonly property bool expanded: scopeHover.hovered
              implicitWidth: expanded ? scopeRow.implicitWidth + 12 : 30
              implicitHeight: 22
              radius: 11
              color: expanded ? chin.itemHover : Qt.alpha(chin.itemHover, 0)
              border.width: 1
              border.color: "transparent"
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
        }
      }

      // Composer — real text input (i to enter, Esc/Ctrl+h to leave). Hidden while an
      // ask is pending: the question TAKES OVER the input rather than floating above a
      // composer that still looks ready for an unrelated message.
      Rectangle {
        objectName: "composerFrame"
        TapHandler { onTapped: { if (!rail.focused) rail.requestFocus(); rail.enterInsert() } }
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        visible: (!rail.pendingAsk || rail.askDeferred) && !rail.newOpen
        // Grows with the text up to ~3 lines (slqs Composer pattern); beyond that the
        // Flickable scrolls the caret into view.
        implicitHeight: Math.max(52, Math.min(composerInput.implicitHeight + 30, 94))
        radius: Math.min(height / 2, 26)   // pill at one line, rounded card when grown
        color: "transparent"
        border.width: 0
        ContrastCard {
          anchors.fill: parent
          cardRadius: parent.radius
          elevated: false
          faceTop: Theme.mode === "light" ? rail.userCardBottom : rail.userCardTop
          faceUpper: faceTop
          faceMid: rail.userCardBottom
          faceBottom: faceMid
        }
        Rectangle {
          anchors.fill: parent
          visible: Theme.mode !== "light"
          radius: parent.radius
          color: "transparent"
          border.color: rail.insert ? rail.activeRing : Theme.hairline
          border.width: rail.insert ? 1.5 : 1
          Behavior on border.color { ColorAnimation { duration: 650; easing.type: Easing.InOutQuad } }
        }
        LightKey {
          anchors.fill: parent
          visible: Theme.mode === "light"
          radius: parent.radius
          ring: rail.insert ? 1.5 : 1
          outline: rail.insert ? rail.activeRing : Qt.alpha(Theme.fg, 0.16)
          fade: 650
        }
        RowLayout {
          anchors { fill: parent; leftMargin: 12; rightMargin: 52 }
          spacing: 8
          Icon {
            name: "chevron-right"; width: 14; height: 14
            // Rides the outline exactly (same hue, same glide) so prompt + frame
            // read as one piece of chrome.
            color: rail.insert ? rail.activeRing : chin.hairline
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
            onActiveFocusChanged: if (activeFocus) { if (!rail.focused) rail.requestFocus(); rail.enterInsert() }
            width: composerFlick.width
            padding: 0
            background: null
            wrapMode: TextArea.Wrap
            color: chin.fg
            font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
            onCursorRectangleChanged: composerFlick.ensureVisible(cursorRectangle)
            onTextChanged: if (!text.length) feedDebounce.restart()
            // Orange blinking caret, matching the sibling apps (Theme.cursor).
            cursorDelegate: Rectangle { width: 2; radius: 1; color: Theme.cursor; opacity: composerInput.cursorVisible && !rail.caretHeld ? 1 : 0 }
            // TextArea has no onAccepted — plain Enter routes here from Keys below.
            // Shift+Enter falls through to the default handler = a newline.
            function sendNow() {
              if (rail.planDraft && !rail.pendingAsk) { rail.sendPlanDraft(); return }
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
              // pi's /reload is TUI-only; under agentd, restarting the scope's agentd respawns every pi.
              if (/^\/reload\s*$/.test(text)) {
                Quickshell.execDetached(["bash", "-c",
                  "cockpit-agentd-restart " + rail.scopeMode + " >> \"$HOME/.local/state/cockpit/agentd-restart.log\" 2>&1"])
                if (rail.agentd) rail.agentd._setTransient(rail.selectedRaw, "reload", "info",
                  "↻ restarting the " + rail.scopeMode + " agentd — sessions resume on next use; log: ~/.local/state/cockpit/agentd-restart.log", 15000)
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
                if (!text.trim().length || !rail.answerAsk({ value: text })) return
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
                rail.clearCode()
                rail.rosterOverride = false   // sending = focus the conversation; roster compacts
              }
              rail.pastedImages = []      // attachments belong to the message just sent
              text = ""
              feedDebounce.stop()
              rail.feedTick++
              feedScroll.toEnd()
              rail._resyncFeed()
              if (pa && (pa.method === "input" || pa.method === "editor")) rail.exitInsert()
              else composerInput.forceActiveFocus()
            }
            Keys.onPressed: (e) => {
              var ctrl = (e.modifiers & Qt.ControlModifier)
              if (ctrl && e.key === Qt.Key_P) { rail.requestPlanMenu(); e.accepted = true; return }
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
                if (rail.planDraft) { feedbackPill.show("Use Enter to send a plan action"); e.accepted = true; return }
                if (rail.agentd && rail.selectedRaw && rail.attachRefs(text).trim().length) {
                  rail.agentd.enqueue(rail.selectedRaw, rail.attachRefs(text))
                  rail.clearCode()
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
              color: chin.muted; font: composerInput.font
            }
          }
          }
        }
        // Concentric with the pill's one-line end cap: 7px clear of the frame on all sides.
        Item {
          objectName: "composerStatus"
          anchors { right: parent.right; rightMargin: 7; top: parent.top; topMargin: 7 }
          width: 38; height: 38
          readonly property var colors: rail.fleetActivityColors(rail.featured.rawName)
          readonly property bool asking: !!rail.pendingAsk
          ThinkingOrb {
            anchors.fill: parent
            visible: !parent.asking && parent.colors.length > 0
            running: visible
            activityColors: parent.colors
            glow: activityColors.length ? activityColors[0] : rail.actionGlow(rail.featured.rawName)
            seedKey: rail.featured.rawName
          }
          Rectangle {
            anchors.centerIn: parent
            visible: parent.asking || parent.colors.length === 0
            width: 10; height: 10; radius: 5
            color: parent.asking ? Theme.orange : rail.dotColor(rail.featured.status)
          }
        }
      }

    }
  }

  component SessionDot: Item {
    required property string sid
    property string status: ""
    property real size: 16
    readonly property bool hasAsk: {
      rail.agentd ? rail.agentd.askGen : 0
      return rail.agentd ? rail.agentd.askFor(sid) !== null : false
    }
    readonly property var colors: rail.fleetActivityColors(sid)
    readonly property bool orbActive: !hasAsk && colors.length > 0
    width: size; height: size
    // Same idle treatment as the dashboard cards: the swirl eases to a stop and greys out.
    ThinkingOrb {
      id: dotOrb
      objectName: "rootActivityOrb"
      anchors.fill: parent
      visible: !parent.hasAsk
      running: true
      activityColors: parent.colors
      glow: activityColors.length ? activityColors[0] : "#999999"
      colorDuration: 1600
      seedKey: parent.sid
      property real motion: parent.orbActive ? 1 : 0
      idleBlur: 1 - motion
      property real elapsed: 0
      clockNow: elapsed
      Behavior on motion { NumberAnimation { duration: 1800; easing.type: Easing.InOutCubic } }
      FrameAnimation {
        running: dotOrb.visible && dotOrb.motion > 0
        onTriggered: dotOrb.elapsed += frameTime * 1000 * dotOrb.motion
      }
    }
    Rectangle {
      anchors.centerIn: parent
      visible: parent.hasAsk
      width: parent.hasAsk ? 9 : 7; height: width; radius: width / 2
      color: parent.hasAsk ? Theme.orange : rail.dotColor(parent.status)
      opacity: parent.hasAsk ? 0.675 + 0.325 * Math.cos((OrbClock.now % 1200) / 1200 * 2 * Math.PI) : 1
    }
  }
  component NewSessionButton: Rectangle {
    width: 28; height: 28; radius: 14
    color: newSessHover.hovered ? chin.itemHover : "transparent"
    Icon { anchors.centerIn: parent; name: "plus--outline--18"; width: 13; height: 13; color: newSessHover.hovered ? chin.fg : chin.muted }
    HoverHandler { id: newSessHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: rail.openNew() }
  }

  component InlineSessions: Item {
      implicitHeight: 28
      height: 28
      readonly property color inlineFace: Theme.mode === "light" ? "#FCFCFC" : rail.userCardTop
      Flickable {
        id: inlineList
        objectName: "sessionTabStrip"
        anchors { left: parent.left; right: inlineNew.left; rightMargin: 4; top: parent.top }
        height: 28
        contentWidth: inlineRowItems.width
        contentHeight: height
        flickableDirection: Flickable.HorizontalFlick
        // Flickable's own touchpad handling drags ~2px per event and starves ScrollFeel.
        interactive: false
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        readonly property int focusIndex: rail.rosterExpanded && rail.cur < rail.rSize ? rail.cur : rail._rosterIndexOf(rail.selectedRaw)
        readonly property bool overflowing: contentWidth > width + 1
        function maxX() { return Math.max(0, contentWidth - width) }
        function reveal() {
          var item = focusIndex >= 0 ? inlineRepeater.itemAt(focusIndex) : null
          if (!item) return
          // Laid-out position, not item.x: a reordered tab is still mid-slide.
          var x0 = 0
          for (var i = 0; i < focusIndex; i++) x0 += inlineRepeater.itemAt(i).width + inlineRowItems.spacing
          var target = contentX
          if (x0 < contentX + 24) target = x0 - 24
          else if (x0 + item.width > contentX + width - 24) target = x0 + item.width - width + 24
          target = Math.max(0, Math.min(maxX(), target))
          inlineReveal.stop()
          if (Math.abs(target - contentX) < 0.5) return
          inlineReveal.to = target; inlineReveal.restart()
        }
        onFocusIndexChanged: Qt.callLater(reveal)
        onWidthChanged: Qt.callLater(reveal)
        NumberAnimation { id: inlineReveal; target: inlineList; property: "contentX"; duration: Motion.base; easing.type: Easing.OutCubic }
        ScrollFeel { flick: inlineList; onScrolled: inlineReveal.stop() }
        Row {
          id: inlineRowItems
          spacing: 8
          // Spring only for a reorder; a pill growing on hover pushes its neighbours directly,
          // so they move in step with its width animation.
          property bool reordering: false
          Timer { id: reorderSettle; interval: 700; onTriggered: inlineRowItems.reordering = false }
          Connections {
            target: rail
            function onTabRecencyChanged() { inlineRowItems.reordering = true; reorderSettle.restart() }
          }
          move: reordering ? reorderSpring : null
          Transition { id: reorderSpring; SpringAnimation { properties: "x"; spring: 8; damping: 0.55; epsilon: 0.25 } }
          Repeater {
          id: inlineRepeater
          model: rosterModel
          onCountChanged: Qt.callLater(inlineList.reveal)
          delegate: Rectangle {
          id: pill
          objectName: "sessionTab"
          readonly property var md: model.d
          readonly property string sid: md.rawName || md.name
          readonly property bool selected: sid === rail.selectedRaw || sid === rail.selectedParent
          readonly property bool offline: md.offline === true || md.status === "offline"
          readonly property bool cursor: rail.rosterExpanded && rail.focused && !rail.insert && rail.cur === index
          height: 28; radius: 14
          width: Math.round(inlineRow.implicitWidth) + 2 + 12
          onWidthChanged: if (selected) Qt.callLater(inlineList.reveal)
          readonly property bool lightKey: selected && Theme.mode === "light"
          readonly property bool darkKey: selected && !cursor && Theme.mode !== "light"
          // Pills slide under a still pointer while re-sorting; hover would flash each one.
          readonly property bool hovered: inlineHover.hovered && !inlineRowItems.reordering
          // Rest at a clear copy of the hover colour: fading from transparent black dips through grey.
          color: lightKey || darkKey ? Qt.alpha(chin.itemHover, 0) : selected ? chin.itemSelected : hovered || cursor ? chin.itemHover : Qt.alpha(chin.itemHover, 0)
          border.width: lightKey || darkKey ? 0 : cursor ? 1.5 : selected ? 1 : 0
          border.color: cursor ? rail.activeRing : chin.hairline
          Behavior on color { ColorAnimation { duration: 140 } }
          GradientFrame {
            anchors.fill: parent
            visible: pill.darkKey
            radius: pill.radius
            fill: Qt.tint(rail.userCardTop, chin.itemSelected)
            edge: chin.fg
          }
          LightKey {
            anchors.fill: parent
            visible: pill.lightKey
            radius: pill.radius
            ring: pill.cursor ? 1.5 : 1
            convex: true
            outline: pill.cursor ? rail.activeRing : Qt.alpha(chin.fg, 0.16)
          }
          Row {
            id: inlineRow
            anchors { left: parent.left; leftMargin: 2; verticalCenter: parent.verticalCenter }
            SessionDot { id: pillDot; anchors.verticalCenter: parent.verticalCenter; sid: pill.sid; status: pill.md.status || pill.md.state || ""; size: pill.height - 4
              scale: pill.selected || pill.hovered || pill.cursor || orbActive || hasAsk ? 1 : 0.67
              Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } } }
            Item { width: 7; height: 1 }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: pill.md.name
              color: pill.selected || pill.cursor || pill.hovered ? chin.fg : chin.muted
              font.family: rail.messageFontFamily; font.pixelSize: rail.fsMeta
              font.weight: pill.selected ? 600 : 400
            }
            // Offline always shows; the remote cloud only while hovered or under the keyboard cursor.
            Item {
              readonly property bool shown: pill.offline || (pill.md.remote === true && (inlineHover.hovered || pill.cursor))
              anchors.verticalCenter: parent.verticalCenter
              visible: width > 0.5
              width: shown ? 4 + pillDot.size : 0; height: pillDot.size
              opacity: shown ? 1 : 0
              clip: true
              Behavior on width { NumberAnimation { duration: Motion.base; easing.type: Easing.OutCubic } }
              Behavior on opacity { NumberAnimation { duration: Motion.base; easing.type: Easing.OutCubic } }
              Icon {
                anchors.right: parent.right
                width: pillDot.size; height: pillDot.size
                name: pill.offline ? "bolt-slash" : "cloud--outline--18"
                color: pill.offline ? Theme.red : rail.skyAccent
              }
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              leftPadding: 6
              visible: pill.selected && rail.selectedParent === pill.sid
              text: "› " + rail.shortName(rail.selectedRaw)
              color: chin.fg
              font.family: rail.messageFontFamily; font.pixelSize: rail.fsMeta; font.weight: 600
            }
          }
          readonly property string tip: sid === rail.selectedRaw ? (rail.activeTask || rail.selectedPlan) : String(md.plan || "")
          HoverHandler {
            id: inlineHover; cursorShape: Qt.PointingHandCursor
            onHoveredChanged: {
              if (hovered && pill.tip.length) rail.showPillTip(pill, pill.tip)
              else if (rail.pillTipFor === pill) rail.pillTipFor = null
            }
          }
          TapHandler { onTapped: rail.clickAt(index) }
        }
        }
        }
      }
      Rectangle {
        anchors { left: inlineList.left; top: inlineList.top; bottom: inlineList.bottom }
        width: 28
        visible: inlineList.overflowing
        opacity: Math.min(1, inlineList.contentX / 24)
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0; color: inlineFace }
          GradientStop { position: 1; color: Qt.alpha(inlineFace, 0) }
        }
      }
      Rectangle {
        anchors { right: inlineList.right; top: inlineList.top; bottom: inlineList.bottom }
        width: 28
        visible: inlineList.overflowing
        opacity: Math.min(1, (inlineList.maxX() - inlineList.contentX) / 24)
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0; color: Qt.alpha(inlineFace, 0) }
          GradientStop { position: 1; color: inlineFace }
        }
      }
      DragHandler {
        objectName: "sessionTabTouchDrag"
        target: null
        acceptedDevices: PointerDevice.TouchScreen
        yAxis.enabled: false
        property real startX: 0
        onActiveChanged: if (active) { inlineReveal.stop(); startX = inlineList.contentX }
        onTranslationChanged: if (active) inlineList.contentX = Math.max(0, Math.min(inlineList.maxX(), startX - translation.x))
      }
      NewSessionButton { id: inlineNew; anchors { right: parent.right; verticalCenter: inlineList.verticalCenter } }
  }

  component InlinePicker: Rectangle {
    required property var entries
    required property int choice
    property string prefix: "/"
    property string rowIcon: "bolt-lightning"
    signal picked(int index)
    width: Math.min(340, parent ? parent.width : 340)
    height: visible ? Math.min(entries.length * 32 + 8, 248) : 0
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
              name: pickerRow.isSkill ? "puzzle-piece" : rowIcon
              width: 14; height: 14
              color: pickerRow.sel ? Theme.fg : Theme.fg_muted
            }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: prefix + modelData
            color: pickerRow.sel ? Theme.fg : Theme.fg_secondary
            font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
            width: parent.width - 29; elide: Text.ElideMiddle
          }
        }
        HoverHandler { id: pickerHover }
        TapHandler { onTapped: picked(pickerRow.index) }
      }
    }
  }

  Column {
    visible: rail.planMenu !== null
    anchors { left: parent.left; bottom: chin.top; leftMargin: 20; bottomMargin: 6 }
    spacing: 6
    Text { text: rail.planMenu ? rail.planMenu.title : ""; color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta }
    InlinePicker {
      objectName: "planActionMenu"
      width: Math.min(420, rail.width - 40)
      entries: rail.planMenu ? rail.planMenu.labels : []
      choice: rail.planChoice; prefix: ""; rowIcon: "clipboard-check"
      onPicked: index => rail.choosePlan(index)
    }
  }
  InlinePicker {
    objectName: "lifecyclePicker"
    visible: rail.lifecycleTarget !== null
    anchors { left: parent.left; bottom: chin.top; leftMargin: 20; bottomMargin: 6 }
    width: Math.min(520, rail.width - 40); z: 20
    entries: rail.lifecycleEntries; choice: 0; prefix: ""; rowIcon: "bolt-lightning"
    onPicked: index => rail.chooseLifecycle(index)
  }

  InlinePicker {
    id: modelPalette
    objectName: "modelPalette"
    visible: rail.modelOpen
    anchors { left: parent.left; bottom: chin.top; leftMargin: 20; bottomMargin: 6 }
    width: Math.min(340, parent.width - 40)
    entries: rail.modelEntries.map(function(m) { return String(m.id) })
    choice: rail.modelCur
    prefix: ""
    onPicked: index => rail.chooseModel(index)
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
      implicitHeight: ubCol.implicitHeight + 24
      radius: 9
      color: Theme.bgDim
      readonly property bool waiting: !entry.failed && !String(entry.result || "").length
                                      && rail.pendingUserBash
                                      && String(rail.pendingUserBash.command || "") === String(entry.command || "")
      border.width: 1
      border.color: entry.failed ? Theme.red : Theme.hairline
      Column {
        id: ubCol
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
        spacing: 6
        RowLayout {
          width: parent.width
          Icon { name: "keyboard"; width: 16; height: 16; color: entry.failed ? Theme.red : Theme.orange; Layout.alignment: Qt.AlignVCenter }
          Text {
            text: "! " + String(entry.command || "")
            color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
            wrapMode: Text.WordWrap; Layout.fillWidth: true
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
          width: parent.width; implicitHeight: ubResult.implicitHeight + 24
          radius: 7; color: Theme.surface0
          Text {
            id: ubResult
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
            text: String(entry.result || "")
            color: entry.failed ? Theme.red : Theme.fg_secondary
            font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
  Component {
    id: activityRow
    Column {
      id: actCol
      width: parent ? parent.width : 400
      spacing: 9
      readonly property var compactItems: rail.activityRows(items)
      readonly property var tools: rail.activityEntries(items)
      readonly property bool smallTurn: rail.smallTurn(tools)
      readonly property bool toolsOpen: smallTurn || rail.groupOpen(ekey + "-tools") || (rail.fileSelectOpen && rail.fileChoiceKey === ekey)
      readonly property var unresolved: rail.unresolvedFailures(tools)
      // Closed shows what other harnesses show by default: changes, actions, live and unresolved work; reads stay behind the toggle.
      readonly property var shownTools: {
        if (toolsOpen) return compactItems
        rail.agentd ? rail.agentd.curToolGen : 0
        var id = rail.agentd ? rail.agentd.curToolIdFor(rail.selectedRaw) : ""
        return compactItems.filter(activity => rail.usefulActivity(activity, unresolved, id))
      }
      // Rings sit beside rows, never inside a Row/RowLayout, which would give them layout space.
      Item {
        visible: rail.turnThinks(items).length > 0
        x: 12; width: actCol.width - 24; height: reasoningRow.implicitHeight
        ItemFocus { itemKey: ekey; anchors.fill: reasoningRow }
      Row {
        id: reasoningRow
        width: parent.width
        spacing: 8
        Icon {
          name: expanded ? "chevron-down" : "chevron-right"
          width: 12; height: 12; color: actCol.parent.mutedColor
          anchors.verticalCenter: parent.verticalCenter
        }
        Text {
          text: "Reasoning"; color: actCol.parent.mutedColor
          font.family: rail.labelFontFamily; font.styleName: rail.labelFontStyle(400); font.pixelSize: rail.fsMeta
        }
        TapHandler { gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: rail.toggleGroupKey(ekey, actCol.parent.defaultReasoning) }
        HoverHandler { cursorShape: Qt.PointingHandCursor }
      }
      }
      Repeater {
        id: thinkRep
        readonly property var thoughts: expanded ? rail.turnThinks(items).filter(thought => rail.expandedGroups[ekey] === true || rail.claudeThought(thought)) : []
        model: CountModel { size: thinkRep.thoughts.length }
        Loader {
          x: 12; width: actCol.width - 24
          sourceComponent: thinkRow
          property var entry: thinkRep.thoughts[index] || ({})
          property string gkey: ekey + "-think-" + (entry.mid || index)
          property bool expanded: rail.groupOpen(gkey, rail.claudeThought(entry))
          property color mutedColor: actCol.parent.mutedColor
        }
      }
      Item {
        visible: actCol.tools.length > 0 && !actCol.smallTurn
        x: 12; width: actCol.width - 24; height: detailsRow.implicitHeight
        ItemFocus { itemKey: ekey + "-tools"; anchors.fill: detailsRow }
      RowLayout {
        id: detailsRow
        objectName: "work-details:" + ekey
        width: parent.width
        spacing: 8
        Icon {
          name: actCol.toolsOpen ? "chevron-down" : "chevron-right"
          width: 12; height: 12; color: actCol.parent.mutedColor
          Layout.minimumWidth: 12; Layout.maximumWidth: 12
        }
        Text {
          text: "Work details · " + actCol.tools.length + (actCol.tools.length === 1 ? " tool" : " tools")
          color: actCol.parent.mutedColor
          font.family: rail.labelFontFamily; font.styleName: rail.labelFontStyle(400); font.pixelSize: rail.fsMeta
          elide: Text.ElideRight; Layout.fillWidth: true
        }
        Text {
          readonly property int failures: actCol.tools.filter(tool => tool.failed === true).length
          visible: failures > 0
          text: failures + " failed"; color: actCol.unresolved.length > 0 ? Theme.red : actCol.parent.mutedColor
          font.family: rail.labelFontFamily; font.styleName: rail.labelFontStyle(400); font.pixelSize: rail.fsMeta
        }
        TapHandler { gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: rail.toggleGroupKey(ekey + "-tools") }
        HoverHandler { cursorShape: Qt.PointingHandCursor }
      }
      }
      Repeater {
        model: CountModel { size: actCol.shownTools.length }
        Loader {
          id: toolLoader
          x: 24; width: actCol.width - 24
          Component.onCompleted: rail.probeActCreates++
          readonly property StreamReveal appear: StreamReveal { fade: toolLoader; live: rail.featuredStreaming }
          readonly property var activity: actCol.shownTools[index] || ({})
          property var entry: activity.kind === "edits" && activity.files.length === 1 ? activity.files[0] : activity
          property bool grouped: false
          property string gkey: activity.kind === "edits" && activity.files.length === 1
            ? rail.toolKey(rail.toolKey(ekey, activity, index), entry, 0) : rail.toolKey(ekey, entry, index)
          property string cardKey: ekey
          property var items: actCol.parent.items
          property bool expanded: rail.expandedGroups[gkey] === true
          property bool fileSelected: rail.fileSelectOpen && rail.fileChoiceKey === ekey
            && rail.activityFileRefs({kind:"turn",items:items})[rail.fileChoiceCur] === entry.path
          property color textColor: actCol.parent.textColor
          property color mutedColor: actCol.parent.mutedColor
          sourceComponent: activity.kind === "edits" ? (activity.files.length > 1 ? editGroup : editActivityRow) : cmdRow
        }
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
      readonly property bool isShell: entry.tool === "bash" || entry.tool === "shell"
      readonly property bool isFailed: entry.failed === true
      // Bash rows carry the raw command — tap toggles it open underneath.
      readonly property bool canExpand: !isErr && !!(entry.result || entry.command) && entry.tool !== "read" && entry.tool !== "read_file" && (!rail.sourceTool(entry) || entry.failed)
      readonly property bool open: typeof gkey !== "undefined" && rail.expandedGroups[gkey] === true
      Item {
        x: 12; width: cmdCol.width - 24; height: commandRowLayout.implicitHeight
        ItemFocus { itemKey: typeof gkey !== "undefined" ? gkey : ""; anchors.fill: commandRowLayout }
      RowLayout {
        id: commandRowLayout
        width: parent.width
        spacing: 8
        FontMetrics { id: commandFont; font: commandLabel.font }
        Icon {
          name: rail.toolIcon(entry.tool); width: 16; height: 16
          color: (cmdCol.isErr || cmdCol.isFailed) ? Theme.red : Theme.fg_muted
          Layout.minimumWidth: 16; Layout.maximumWidth: 16
          Layout.minimumHeight: 16; Layout.maximumHeight: 16
          Layout.alignment: Qt.AlignTop
          Layout.topMargin: Math.max(0, commandLabel.baselineOffset + commandFont.tightBoundingRect(commandLabel.text).y + commandFont.tightBoundingRect(commandLabel.text).height / 2 - 8)
        }
        Text {
          id: commandLabel
          textFormat: Text.PlainText
          readonly property bool liveNow: {
            rail.agentd ? rail.agentd.curToolGen : 0
            return !!(rail.agentd && entry.id && rail.agentd.curToolIdFor(rail.selectedRaw) === entry.id)
          }
          text: ((entry.tool === "read" || entry.tool === "read_file") && rail.toolFiles(entry).length
            ? "read " + rail.toolFiles(entry)[0].split("/").pop() + rail.readRange(entry)
            : (cmdCol.isShell ? rail.commandTitle(entry.command || entry.text) : entry.text))
                + (entry.runs ? "  ×" + entry.runs.length : "") + (cmdCol.isFailed ? "  — failed" : "")
                + (liveNow ? "  · " + rail.runningToolLabel(rail.selectedRaw).split("· ").pop() : "")
          color: cmdCol.isErr ? Theme.red : (cmdCol.isFailed ? Theme.red : Theme.fg_secondary)
          font.family: Theme.fontFamily
          font.pixelSize: rail.fsMeta - 2
          wrapMode: cmdCol.isErr ? Text.WordWrap : Text.NoWrap
          elide: cmdCol.isErr ? Text.ElideNone : Text.ElideRight
          maximumLineCount: cmdCol.isErr ? 9999 : 1
          lineHeight: cmdCol.isErr ? 1.3 : 1
          Layout.fillWidth: true
        }
        Icon {
          visible: cmdCol.canExpand
          opacity: cmdCol.open || cmdHover.hovered || (rail.itemMode && rail.itemFocus === gkey) ? 1 : 0
          name: cmdCol.open ? "chevron-down" : "chevron-right"
          width: 11; height: 11; color: Theme.fg_muted
          Layout.alignment: Qt.AlignVCenter
        }
        TapHandler { enabled: cmdCol.canExpand; onTapped: rail.toggleGroupKey(gkey) }
        HoverHandler { id: cmdHover; enabled: cmdCol.canExpand; cursorShape: Qt.PointingHandCursor }
      }
      }
      Loader {
        width: cmdCol.width
        active: !!(entry.command || entry.result || entry.argumentsText || entry.detailsText)
        visible: active
        property var entry: cmdCol.parent.entry
        property bool grouped: false
        property string gkey: cmdCol.parent.gkey
        property bool expanded: cmdCol.open
        sourceComponent: toolResultRow
      }
    }
  }
  Component {
    id: editGroup
    Item {
      id: writeCardBox
      width: parent ? parent.width : 400
      implicitHeight: writeCard.implicitHeight + 12
      Rectangle {
        id: writeCard
        y: 6; width: parent.width
        implicitHeight: writeCardCol.implicitHeight
        radius: 10
        color: Qt.rgba((Theme.canvas.r + rail.userCardBottom.r) / 2,
                       (Theme.canvas.g + rail.userCardBottom.g) / 2,
                       (Theme.canvas.b + rail.userCardBottom.b) / 2, 1)
        border.width: 1; border.color: Theme.hairline
        readonly property var files: writeCardBox.parent.entry.files || []
        Column {
          id: writeCardCol
          width: parent.width
          Item {
            width: parent.width; implicitHeight: writeTitle.implicitHeight + 24
            RowLayout {
              id: writeHeading
              anchors.fill: parent; anchors.margins: 12
              spacing: 8
              Icon {
                name: "square-plus"; width: 16; height: 16; color: Theme.fg_muted
                Layout.minimumWidth: 16; Layout.maximumWidth: 16
                Layout.minimumHeight: 16; Layout.maximumHeight: 16
              }
              Text {
                id: writeTitle
                text: (writeCard.files.some(file => file.partial) ? "Editing " : writeCard.files.some(file => file.failed) ? "File changes · " : "Edited ") + writeCard.files.length + " files"
                color: Theme.fg_secondary; font.family: rail.messageFontFamily; font.pixelSize: rail.fsMeta
                elide: Text.ElideRight; Layout.maximumWidth: Math.max(0, writeHeading.width - writeDiff.implicitWidth - 48)
              }
              Row {
                id: writeDiff
                spacing: 6
                Text { text: "+" + writeCard.files.reduce((total,file) => total + file.add,0); color: Theme.green; font.family: rail.messageFontFamily; font.pixelSize: rail.fsMeta }
                Text { text: "-" + writeCard.files.reduce((total,file) => total + file.del,0); color: Theme.red; font.family: rail.messageFontFamily; font.pixelSize: rail.fsMeta }
              }
              Item { Layout.fillWidth: true }
            }
          }
          Repeater {
            model: writeCard.files
            Column {
              width: writeCardCol.width
              Rectangle { width: parent.width; height: 1; color: Theme.hairline }
              Loader {
                width: parent.width
                property bool grouped: true
                property var entry: modelData
                property string gkey: rail.toolKey(writeCardBox.parent.gkey, entry, index)
                property bool expanded: rail.expandedGroups[gkey] === true
                property bool fileSelected: rail.fileSelectOpen && rail.fileChoiceKey === writeCardBox.parent.cardKey
                  && rail.activityFileRefs({kind:"turn",items:writeCardBox.parent.items})[rail.fileChoiceCur] === entry.path
                property color textColor: writeCardBox.parent.textColor
                property color mutedColor: writeCardBox.parent.mutedColor
                sourceComponent: editActivityRow
              }
            }
          }
        }
      }
    }
  }
  Component {
    id: editActivityRow
    Column {
      id: editCol
      width: parent ? parent.width : 400
      spacing: 6
      Loader {
        width: parent.width
        property var entry: editCol.parent.entry
        property bool grouped: editCol.parent.grouped
        property bool fileSelected: editCol.parent.fileSelected
        property color textColor: editCol.parent.textColor
        property color mutedColor: editCol.parent.mutedColor
        property string gkey: editCol.parent.gkey
        property bool expanded: editCol.parent.expanded
        sourceComponent: editRow
      }
      Loader {
        x: editCol.parent.grouped ? 12 : 0
        width: parent.width - 2 * x
        property var entry: editCol.parent.entry
        property string gkey: editCol.parent.gkey
        active: editCol.parent.expanded && !entry.failed && rail.entryDiff(entry).length > 0
        visible: active
        sourceComponent: editDiffPanel
      }
      Loader {
        x: editCol.parent.grouped ? 12 : 0
        width: parent.width - 2 * x
        property var entry: editCol.parent.entry
        property bool grouped: editCol.parent.grouped
        property string gkey: editCol.parent.gkey
        property bool expanded: editCol.parent.expanded
        active: !!(entry.result || entry.argumentsText || entry.detailsText)
        visible: active
        sourceComponent: toolResultRow
      }
      Item {
        width: 1; height: 6
        visible: editCol.parent.grouped && (editCol.parent.entry.failed || editCol.parent.expanded)
      }
    }
  }
  Component {
    id: toolResultRow
    Column {
      id: resultCol
      width: parent ? parent.width : 400
      spacing: 6
      readonly property bool showOutput: !rail.sourceTool(entry) || entry.failed
      readonly property bool grouped: parent.grouped
      Flow {
        x: resultCol.grouped ? 0 : 12; width: parent.width - 2 * x
        spacing: 8
        visible: expanded && entry.tool !== "read" && entry.tool !== "read_file"
        ButtonSurface {
          primary: false; radius: 6
          visible: resultCol.showOutput && !!entry.result
          width: detailRow.implicitWidth + 16; height: 26
          Row {
            id: detailRow; anchors.centerIn: parent; spacing: 5
            Icon { name: expanded ? "chevron-down" : "chevron-right"; width: 12; height: 12; color: Theme.fg_muted; anchors.verticalCenter: parent.verticalCenter }
            Text { text: expanded ? "Hide details" : "Show details"; color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta - 1 }
          }
          TapHandler { onTapped: rail.toggleGroupKey(gkey) }
        }
        ButtonSurface {
          primary: false; radius: 6
          visible: !!entry.result
          width: copyRow.implicitWidth + 16; height: 26
          Row {
            id: copyRow; anchors.centerIn: parent; spacing: 5
            Icon { name: "clipboard"; width: 12; height: 12; color: Theme.fg_muted; anchors.verticalCenter: parent.verticalCenter }
            Text { text: "Copy output"; color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta - 1 }
          }
          TapHandler { onTapped: rail.copyText(rail.plainToolText(entry.result)) }
          ItemFocus { itemKey: "copyout:" + gkey }
        }
        ButtonSurface {
          primary: false; radius: 6
          visible: !!entry.command
          width: commandRow.implicitWidth + 16; height: 26
          Row {
            id: commandRow; anchors.centerIn: parent; spacing: 5
            Icon { name: "clipboard"; width: 12; height: 12; color: Theme.fg_muted; anchors.verticalCenter: parent.verticalCenter }
            Text { text: "Copy command"; color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta - 1 }
          }
          TapHandler { onTapped: rail.copyText(String(entry.command)) }
          ItemFocus { itemKey: "copycmd:" + gkey }
        }
        Row {
          visible: entry.partial === true; height: 26; spacing: 5
          Icon { name: "clock"; width: 12; height: 12; color: Theme.fg_muted; anchors.verticalCenter: parent.verticalCenter }
          Text { text: "Streaming"; color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta - 1; anchors.verticalCenter: parent.verticalCenter }
        }
      }
      Rectangle {
        objectName: "tool-code-panel:" + (entry.id || entry.tool)
        // Agents fail and retry edits routinely: one quiet line, the full error one click away.
        width: parent.width; implicitHeight: preview.implicitHeight + 4
        visible: entry.failed === true && !expanded && !!entry.result
        color: "transparent"
        Text {
          id: preview
          objectName: "tool-preview:" + (entry.id || entry.tool)
          anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: resultCol.grouped ? 24 : 36; rightMargin: 24 }
          text: rail.errorText(entry).replace(/\s*\n\s*/g, " · ")
          textFormat: Text.PlainText
          maximumLineCount: 1; elide: Text.ElideRight; wrapMode: Text.NoWrap
          color: Theme.red; opacity: 0.85
          font.family: rail.messageFontFamily; font.pixelSize: rail.fsMeta - 2
        }
      }
      Repeater {
        id: outRep
        readonly property var fields: {
          if (expanded && entry.tool === "queue") return [{label:"Queued",value:String(entry.command || ""),hidden:0}]
          if (!expanded || !resultCol.showOutput || !entry.result) return []
          var output = entry.failed ? rail.errorText(entry) : rail.plainToolText(entry.result)
          var lines = output.replace(/\n+$/, "").split("\n")
          var hidden = !entry.failed && rail.expandedGroups[gkey + ":all"] !== true ? Math.max(0, lines.length - rail.outputPreviewLines) : 0
          var fields = [{label:"Output",value:hidden ? lines.slice(hidden).join("\n") : output,hidden:hidden}]
          var details = entry.failed ? rail.errorDetails(entry) : ""
          if (details) fields.push({label:"Details",value:details,hidden:0})
          return fields
        }
        model: fields.length
        Column {
          readonly property var modelData: outRep.fields[index] || ({label: "", value: "", hidden: 0})
          width: resultCol.width
          spacing: 4
          Text { x: resultCol.grouped ? 24 : 36; text: modelData.label; color: Theme.fg_muted; font.family: rail.messageFontFamily; font.pixelSize: rail.fsMeta }
          Text {
            objectName: "tool-earlier:" + (entry.id || entry.tool)
            visible: modelData.hidden > 0
            x: resultCol.grouped ? 24 : 36
            text: "… " + modelData.hidden + " earlier lines · show all"
            color: Theme.fg_muted; font.family: rail.messageFontFamily; font.pixelSize: rail.fsMeta - 1
            TapHandler { onTapped: rail.toggleGroupKey(gkey + ":all") }
            ItemFocus { itemKey: gkey + ":all" }
            HoverHandler { cursorShape: Qt.PointingHandCursor }
          }
          Rectangle {
            width: parent.width; implicitHeight: outputText.implicitHeight + 32
            radius: 8; color: rail.codePanelColor
            border.width: 1; border.color: rail.codePanelBorder
            TextEdit {
              id: outputText
              objectName: "tool-" + modelData.label.toLowerCase() + ":" + (entry.id || entry.tool)
              anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: resultCol.grouped ? 24 : 36; rightMargin: 24; topMargin: 16 }
              height: implicitHeight
              readOnly: true; selectByMouse: true; activeFocusOnPress: false
              readonly property StreamReveal reveal: StreamReveal { full: modelData.value; live: entry.partial === true; snapOnEnd: true }
              text: reveal.text; textFormat: TextEdit.PlainText; wrapMode: TextEdit.WordWrap
              color: entry.failed ? Theme.red : Theme.fg
              font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
            }
          }
        }
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
        Layout.preferredWidth: 16
        Layout.preferredHeight: Math.round(rail.fsBody * 1.3)
        Layout.alignment: Qt.AlignTop
        Rectangle { width: 4; height: 4; radius: 2; color: mutedColor; anchors.centerIn: parent }
      }
      Text {
        readonly property StreamReveal reveal: StreamReveal {
          full: String((typeof expanded !== "undefined" && expanded && entry.full) ? entry.full : (entry.text || ""))
          live: entry.liveThink === true
          arrivedAt: Number(entry.arrivedAt || 0)
        }
        text: reveal.text
        color: mutedColor
        font.family: rail.messageFontFamily; font.pixelSize: rail.fsBody; font.weight: rail.messageMetaWeight
        wrapMode: Text.WordWrap; lineHeight: 1.3; Layout.fillWidth: true
        elide: (typeof expanded !== "undefined" && expanded) ? Text.ElideNone : Text.ElideRight
        maximumLineCount: (typeof expanded !== "undefined" && expanded) ? 9999 : 1
      }
      TapHandler { enabled: typeof gkey !== "undefined"; onTapped: rail.toggleGroupKey(gkey, rail.claudeThought(entry)) }
    }
  }
  Component {
    id: inlineAttachmentContent
    Column {
      id: attachmentLines
      width: parent ? parent.width : 400
      spacing: 0
      readonly property var lines: rail.inlineAttachmentLines(sourceText)
      readonly property color contentColor: parent.bodyColor
      Repeater {
        model: attachmentLines.lines
        Flow {
          id: attachmentLine
          readonly property var tokens: modelData
          width: attachmentLines.width
          height: Math.max(rail.bodyLeading, childrenRect.height)
          Repeater {
            model: attachmentLine.tokens
            Loader {
              property var token: modelData
              property color contentColor: attachmentLines.contentColor
              sourceComponent: token.kind === "image" ? inlineAttachmentChip
                : (token.kind === "file" ? inlineFileChip
                : (token.kind === "code" ? inlineCodeText : inlineAttachmentText))
            }
          }
        }
      }
    }
  }
  Rectangle {
    objectName: "sessionUsageTooltip"
    visible: modelHover.hovered && rail.sessionUsage.length > 0
    x: 20; y: chin.y - height - 8; z: 200
    width: Math.min(rail.width - 40, 620)
    height: usageLabel.implicitHeight + 24
    radius: 10; color: Theme.surface0
    border.width: 1; border.color: Theme.hairline
    Text {
      id: usageLabel
      anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
      text: rail.sessionUsage
      textFormat: Text.PlainText; wrapMode: Text.Wrap
      color: Theme.fg_secondary
      font.family: rail.messageFontFamily; font.pixelSize: rail.fsMeta
    }
  }
  component MessageHintCap: Item {
    property string text: ""
    implicitWidth: Math.max(hintLetter.implicitWidth + 10, 20)
    implicitHeight: 20
    width: implicitWidth
    height: implicitHeight
    Rectangle {
      anchors.fill: parent
      radius: 6
      border.width: 1
      border.color: rail.goldAccent
      gradient: Gradient {
        orientation: Gradient.Vertical
        GradientStop { position: 0; color: Theme.mode === "light" ? "#FFFFFF" : "#3B3B3B" }
        GradientStop { position: 1; color: Theme.mode === "light" ? "#D5D3CF" : "#202020" }
      }
      Rectangle {
        anchors.fill: parent
        anchors.margins: 2
        radius: 4
        gradient: Gradient {
          orientation: Gradient.Vertical
          GradientStop { position: 0; color: Theme.mode === "light" ? "#FBFAF8" : "#1A1A1A" }
          GradientStop { position: 1; color: Theme.mode === "light" ? "#F3F1ED" : "#090909" }
        }
      }
    }
    Text {
      id: hintLetter
      anchors.centerIn: parent
      text: parent.text.toUpperCase()
      color: Theme.mode === "light" ? "#242424" : "#FAFAFA"
      font.family: Theme.fontFamily
      font.pixelSize: rail.fsMeta - 3
      font.weight: 600
    }
  }
  Component {
    id: inlineAttachmentText
    Item {
      width: attachmentWord.implicitWidth
      height: rail.bodyLeading
      Text {
        id: attachmentWord
        anchors.verticalCenter: parent.verticalCenter
        text: token.text
        color: contentColor
        font.family: rail.messageFontFamily; font.pixelSize: rail.fsBody; font.weight: rail.messageBodyWeight
      }
    }
  }
  Component {
    id: inlineCodeText
    Item {
      width: codeWord.implicitWidth + (token.trailing ? 7 : 0)
      height: rail.bodyLeading
      Text {
        id: codeWord
        anchors.verticalCenter: parent.verticalCenter
        text: token.label
        color: Theme.mode === "light" ? rail.goldAccent : Theme.green
        font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta; font.weight: rail.messageBodyWeight
      }
    }
  }
  component InlineAttachmentSurface: Rectangle {
    readonly property color contentColor: Theme.fg
    color: Theme.mode === "light" ? Theme.surface : "transparent"
    border.width: Theme.mode === "light" ? 1 : 0
    border.color: Theme.hairlineSoft
    ButtonSurface {
      anchors.fill: parent
      visible: Theme.mode === "dark"
      primary: false
      radius: parent.radius
    }
  }
  Component {
    id: inlineAttachmentChip
    Item {
      width: imagePill.width + (token.trailing ? 7 : 0)
      height: rail.bodyLeading
      InlineAttachmentSurface {
        id: imagePill
        width: imagePillRow.implicitWidth + 16
        height: rail.bodyLeading
        radius: height / 2
        Row {
          id: imagePillRow
          anchors.centerIn: parent
          spacing: 6
          Icon { name: "image"; width: 12; height: 12; color: "#3F8C69"; anchors.verticalCenter: parent.verticalCenter }
          Text {
            text: token.label
            color: imagePill.contentColor
            font.family: rail.messageFontFamily; font.pixelSize: rail.fsMeta; font.weight: rail.messageMetaWeight
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }
    }
  }
  Component {
    id: inlineFileChip
    Item {
      width: filePill.width + (token.trailing ? 7 : 0)
      height: rail.bodyLeading
      InlineAttachmentSurface {
        id: filePill
        width: filePillRow.implicitWidth + 16
        height: rail.bodyLeading
        radius: height / 2
        Row {
          id: filePillRow
          anchors.centerIn: parent
          spacing: 6
          Icon { name: "file-content"; width: 12; height: 12; color: "#9A6500"; anchors.verticalCenter: parent.verticalCenter }
          Text {
            text: token.label
            color: filePill.contentColor
            font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta; font.weight: rail.messageMetaWeight
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
      spacing: rail.bodyLeading
      readonly property var blocks: rail.markdownBlocks(sourceText, sourceEntry, sourceOffset)
      Repeater {
        model: CountModel { size: markdownRoot.blocks.length }
        Loader {
          width: markdownRoot.width
          property var block: markdownRoot.blocks[index] || ({})
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
        font.family: rail.messageFontFamily; font.pixelSize: rail.fsBody; font.weight: rail.messageBodyWeight
        wrapMode: TextEdit.WordWrap
        textFormat: TextEdit.MarkdownText
        Component.onCompleted: rail.messageBoldFontFamily ? ProseStyle.apply(textDocument, rail.messageBoldFontFamily) : ProseStyle.apply(textDocument)
        onTextChanged: rail.messageBoldFontFamily ? ProseStyle.apply(textDocument, rail.messageBoldFontFamily) : ProseStyle.apply(textDocument)
        onLinkActivated: (u) => Quickshell.execDetached(["xdg-open", u])
      }
      Repeater {
        model: rail.blockHints(block, rowIndex)
        MessageHintCap {
          readonly property string marker: "\u200B[" + modelData.label + "]\u200B"
          readonly property int markerPos: markdownText.getText(0, markdownText.length).indexOf(marker)
          readonly property rect markerRect: markerPos >= 0 ? markdownText.positionToRectangle(markerPos) : Qt.rect(-100, -100, 0, 0)
          x: markerRect.x
          y: markerRect.y + (markerRect.height - height) / 2
          z: 2
          text: modelData.label
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
      color: rail.codePanelColor
      border.width: 1
      border.color: block.runnable && agentAuthored ? rail.summaryColor : rail.codePanelBorder
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
          MessageHintCap {
            visible: fence.activeHint !== null
            text: fence.activeHint ? fence.activeHint.label : ""
            TapHandler { onTapped: if (fence.activeHint) rail.hintKey(fence.activeHint.label) }
          }
        }
        TextEdit {
          width: parent.width
          text: String(block.code || "").replace(/\n$/, "")
          readOnly: true; selectByMouse: true
          wrapMode: TextEdit.WrapAnywhere
          textFormat: TextEdit.PlainText
          color: bodyColor
          font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
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
      spacing: rail.bodyLeading
      readonly property StreamReveal reveal: StreamReveal { full: String(entry.text || ""); live: entry.liveText === true; arrivedAt: Number(entry.arrivedAt || 0) }
      readonly property var parts: rail.proseParts(reveal.text)
      Repeater {
        model: CountModel { size: proseCol.parts.length }
        Loader {
          id: partLoader
          width: proseCol.width
          readonly property var part: proseCol.parts[index] || ({})
          sourceComponent: part.fileRef !== undefined ? fileRefRow
            : (rail.hasInlineBadges(sourceText) ? inlineAttachmentContent : markdownContent)
          property var refData: part
          property string sourceText: part.text || ""
          property int sourceEntry: proseCol.parent.entryIndex
          property int sourceOffset: part.offset || 0
          property int rowIndex: proseCol.parent.rowIndex
          property color bodyColor: part.summary ? rail.summaryColor : proseCol.parent.bodyColor
          property color mutedColor: proseCol.parent.mutedColor
          property bool agentAuthored: true
          readonly property StreamReveal appear: StreamReveal { fade: partLoader; live: proseCol.reveal.revealing }
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
        Icon { name: "file-content"; width: 13; height: 13; color: mutedColor; Layout.alignment: Qt.AlignVCenter }
        MessageHintCap {
          visible: text.length > 0
          text: rail.fileHintFor(refData.path, rowIndex)
        }
        Text {
          text: refData.shown; color: bodyColor
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
    id: editDiffPanel
    Rectangle {
      id: diffPanel
      objectName: "edit-diff:" + (entry.path || "")
      readonly property var rows: rail.diffRows(rail.entryDiff(entry))
      readonly property var shown: rail.expandedGroups[gkey + ":all"] === true ? rows : rows.slice(0, rail.diffPreviewLines)
      readonly property string language: rail.codeLanguage(entry.path)
      width: parent ? parent.width : 400
      implicitHeight: diffCol.implicitHeight + 12
      radius: 6; color: rail.codePanelColor
      border.width: 1; border.color: Theme.hairline
      clip: true
      Column {
        id: diffCol
        anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 6; bottomMargin: 6 }
        Repeater {
          model: diffPanel.shown
          Rectangle {
            readonly property color tone: modelData.sign === "+" ? Theme.green : modelData.sign === "-" ? Theme.red : "transparent"
            width: diffCol.width; height: diffLine.implicitHeight + 3
            color: modelData.sign === "+" ? Theme.diffAddedBg : modelData.sign === "-" ? Theme.diffRemovedBg : "transparent"
            Rectangle { width: 2; height: parent.height; color: parent.tone; visible: modelData.sign !== " " }
            Text {
              id: diffLine
              x: 10; width: parent.width - 16; anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.StyledText
              text: "<font color=\"" + Qt.rgba(Theme.fg_muted.r, Theme.fg_muted.g, Theme.fg_muted.b, 0.75) + "\">"
                + ("    " + modelData.number).slice(-4).replace(/ /g, "&nbsp;") + "&nbsp;&nbsp;</font>"
                + rail.highlightCode(modelData.text, diffPanel.language)
              color: modelData.sign === " " ? Theme.fg_secondary : Theme.fg
              font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta - 2
              wrapMode: Text.NoWrap; elide: Text.ElideRight; maximumLineCount: 1
            }
          }
        }
        Text {
          visible: diffPanel.rows.length > diffPanel.shown.length
          topPadding: 6
          text: "… " + (diffPanel.rows.length - diffPanel.shown.length) + " more lines · show all"
          color: Theme.fg_muted; font.family: rail.messageFontFamily; font.pixelSize: rail.fsMeta - 1
          TapHandler { onTapped: rail.toggleGroupKey(gkey + ":all") }
          ItemFocus { itemKey: gkey + ":all" }
          HoverHandler { cursorShape: Qt.PointingHandCursor }
        }
      }
    }
  }
  Component {
    id: editRow
    Rectangle {
      id: writeRow
      objectName: "writeFileRow"
      readonly property bool hovered: writeHover.hovered
      readonly property bool hasDiff: entry.failed === true || rail.entryDiff(entry).length > 0
      function openFile() { rail.openFileRef(entry.path) }
      HoverHandler { id: writeHover; cursorShape: Qt.PointingHandCursor }
      implicitHeight: rail.fsMeta + (grouped ? 24 : 14)
      radius: 8
      color: fileSelected ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.08) : "transparent"
      border.width: fileSelected ? 1 : 0
      border.color: Theme.hairline
      readonly property bool chevronShown: hasDiff && (expanded || writeHover.hovered || (rail.itemMode && (rail.itemFocus === gkey || rail.itemFocus === "open:" + gkey)))
      RowLayout {
        anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: writeRow.chevronShown ? 31 : 12
        Behavior on anchors.rightMargin { NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic } }
        spacing: 8
        Icon { name: entry.failed ? "triangle-warning" : "file-content"; width: 16; height: 16; color: entry.failed ? Theme.red : mutedColor; Layout.alignment: Qt.AlignVCenter }
        Text { text: rail.pathMarkup(entry.path || entry.file); textFormat: Text.StyledText; color: textColor; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta - 2; elide: Text.ElideRight; Layout.fillWidth: true }
        Text { visible: entry.failed === true; text: "Failed"; color: Theme.red; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta }
        Text { visible: !entry.failed && (entry.add + entry.del) > 0; text: "+" + entry.add; color: Theme.green; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta }
        Text { visible: !entry.failed && (entry.add + entry.del) > 0; text: "-" + entry.del; color: Theme.red; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta }
      }
      Icon {
        id: diffToggle
        objectName: "edit-diff-toggle:" + (entry.path || "")
        anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
        opacity: writeRow.chevronShown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic } }
        name: expanded ? "chevron-down" : "chevron-right"
        width: 11; height: 11; color: mutedColor
      }
      TapHandler {
        onTapped: (point) => writeRow.hasDiff && point.position.x > writeRow.width - 40 ? rail.toggleGroupKey(gkey) : writeRow.openFile()
      }
      ItemFocus { itemKey: "open:" + gkey; anchors.rightMargin: writeRow.hasDiff ? 28 : -4 }
      Item {
        visible: writeRow.hasDiff
        anchors { right: parent.right; top: parent.top; bottom: parent.bottom; rightMargin: 6 }
        width: 22
        ItemFocus { itemKey: gkey }
      }
    }
  }

  Rectangle {
    id: pillTip
    objectName: "sessionPillTip"
    z: 1001
    readonly property point at: {
      var f = rail.pillTipFor
      if (!f) return Qt.point(0, 0)
      f.x; f.width; inlineSessions.x
      var p = f.mapToItem(rail, 0, 0)
      return Qt.point(p.x, p.y)
    }
    x: Math.max(8, Math.min(rail.width - width - 8, at.x))
    y: at.y - height - 8
    width: Math.min(tipText.implicitWidth + 20, rail.width * 0.6)
    height: tipText.implicitHeight + 12
    radius: 8
    color: chin.baseSurface
    border.width: 1
    border.color: chin.hairline
    opacity: rail.pillTipFor ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    Text {
      id: tipText
      anchors.centerIn: parent
      width: parent.width - 20
      text: rail.pillTipText
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: chin.fg
      font.family: rail.messageFontFamily; font.pixelSize: rail.fsMeta - 1
    }
  }

  Rectangle {
    id: keyHints
    objectName: "keyHints"
    anchors.fill: parent
    z: 60
    visible: opacity > 0
    opacity: rail.hintsOpen ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    color: Qt.alpha(rail.railGroundColor, 0.72)
    TapHandler { onTapped: rail.hintsOpen = false }
    readonly property var groups: [
      { t: "Move", k: [["j/k", "down/up"], ["g/G", "top/end"], ["C-j/C-k", "tabs · feed · composer"], ["h", "editor"]] },
      { t: "Act", k: [["i", "write"], ["⏎", "copy/open"], ["⇥", "chat/files"], ["f", "links/run"], ["y/Y", "yank/message"]] },
      { t: "Sessions", k: [["h/l", "tabs"], ["n", "new"], ["x", "kill"], ["S-w", "work/personal"], ["S-p", "bind plan"]] },
      { t: "Writing", k: [["⏎", "send · steer"], ["C-⏎", "queue"], ["/", "commands"], ["C-v", "paste"], ["esc", "normal"]] },
      { t: "Running", k: [["esc", "interrupt"], ["S-esc", "kill tool"]] },
      { t: "Questions", k: [["y/n", "yes/no"], ["1-9", "pick"], ["t", "talk"], ["esc", "cancel"]] }
    ]
    Rectangle {
      id: hintsCard
      anchors.centerIn: parent
      width: Math.min(parent.width - 48, 560)
      height: hintsCol.implicitHeight + 40
      radius: 20
      color: chin.cardSurface
      border.width: 1
      border.color: chin.hairline
      scale: rail.hintsOpen ? 1 : 0.97
      Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
      TapHandler {}
      Column {
        id: hintsCol
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 20 }
        spacing: 16
        Row {
          width: parent.width
          Text {
            width: parent.width - closeCap.width
            text: "KEYS"
            color: chin.fg
            font { family: Theme.fontFamily; pixelSize: rail.fsName; bold: true }
          }
          Row {
            id: closeCap
            spacing: 6
            KeyCap { small: true; px: 11; text: "?"; color: chin.lightMode ? "#F7F9FA" : "#2D2D2D"; border.color: chin.lightMode ? "#C9D1D8" : "#4A4A4A"; textColor: chin.lightMode ? "#4F5961" : "#B5B9BB" }
            CapLabel { px: 12; text: "close"; color: chin.muted }
          }
        }
        Grid {
          width: parent.width
          columns: width >= 480 ? 3 : 2
          columnSpacing: 20
          rowSpacing: 16
          Repeater {
            model: keyHints.groups
            Column {
              required property var modelData
              width: (hintsCol.width - 20 * (parent.columns - 1)) / parent.columns
              spacing: 7
              CapLabel { px: 11; text: modelData.t; color: chin.muted }
              Repeater {
                model: modelData.k
                Row {
                  required property var modelData
                  spacing: 8
                  KeyCap { small: true; px: 11; text: modelData[0]; color: chin.lightMode ? "#F7F9FA" : "#2D2D2D"; border.color: chin.lightMode ? "#C9D1D8" : "#4A4A4A"; textColor: chin.lightMode ? "#4F5961" : "#B5B9BB" }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData[1]
                    color: chin.fg
                    font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

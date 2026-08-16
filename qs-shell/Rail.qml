import QtQuick
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
  // Set by shell.qml from TermView.nvimSocket — the socket THIS instance's nvim listens
  // on. Never rebuild this path here: a guessed shared name is how the rail ended up
  // talking to a socket a newer heidr had already unlinked.
  property string nvimSock: ""
  property bool focused: false
  signal focusNvim()
  signal requestFocus()   // a click in the rail should pull focus here

  // Click a row: focus the rail, move the cursor there, and act on it.
  function clickAt(idx) { requestFocus(); cur = idx; activateCur() }
  // Pull focus to the rail and land on the roster (Super+T from the desktop).
  // Super+T must work from ANYWHERE, including while typing: the composer holds the
  // keyboard in insert mode, so moving `cur` alone did nothing visible. Leave insert
  // and clear the restore flag, or the next focus change would drop you back into it.
  function focusRoster() {
    if (rosterOverride === false) rosterOverride = true
    exitInsert()
    _wasInsert = false
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
      onStreamFinished: rail.commands = String(this.text || "").split("\n").filter(s => s.length > 0)
    }
  }

  // ── vimium-style link hints (mlqs `f` mode) ─────────────────────────────────
  // `f` labels every link in the FOCUSED message with a code-styled badge;
  // typing the label opens it. Labels are injected into the markdown (same
  // approach as mlqs) rather than positioned overlays — Text gives no per-link
  // geometry, and a single regex drives BOTH collection and injection so the
  // label order can't drift from the target order.
  property bool hinting: false
  property var hintLabels: []
  property var hintTargets: []
  property int hintIdx: -1          // feed row the hints belong to
  readonly property string hintChars: "asdfghjklqwertyuiopzxcvbnm"
  function _linkRe() { return /\[[^\]]*\]\((https?:\/\/[^\s)]+)\)|(https?:\/\/[^\s<>")\]]+)/g }
  function startHints() {
    if (view !== "chat" || cur < rSize) return
    var idx = cur - rSize
    var txt = feedCopyTarget(groupedFeed[idx])
    var re = _linkRe(), m, urls = []
    while ((m = re.exec(String(txt || ""))) !== null) urls.push(m[1] || m[2])
    if (!urls.length) return
    var labels = []
    for (var i = 0; i < urls.length; i++) labels.push(hintChars.charAt(i % hintChars.length))
    hintTargets = urls; hintLabels = labels; hintIdx = idx; hinting = true
  }
  // Yank-hints (mlqs's y, on the f-hint chassis): label the COPYABLE units of the
  // focused message — fenced code blocks, inline code, links — and a letter copies
  // that unit; `yy` copies the whole message. ONE regex is shared by the extractor
  // and the badge pass (hintify), so labels and targets can never drift apart.
  property bool yankMode: false
  onViewChanged: if (hinting) cancelHints("view")
  function _yankRe() {
    return /```[a-zA-Z]*\n([\s\S]*?)```|`([^`\n]+)`|\[[^\]]*\]\((https?:\/\/[^\s)]+)\)|(https?:\/\/[^\s<>")\]]+)/g
  }
  function startYank() {
    if (view !== "chat" || cur < rSize) return
    var idx = cur - rSize
    var txt = String(feedCopyTarget(groupedFeed[idx]) || "")
    var re = _yankRe(), m, targets = []
    while ((m = re.exec(txt)) !== null) targets.push(m[1] || m[2] || m[3] || m[4] || m[0])
    // No units still enters the mode: yy (whole message) is always on the table.
    var labels = [], chars = hintChars.replace("y", "")   // y is reserved for yy
    for (var i = 0; i < targets.length; i++) labels.push(chars.charAt(i % chars.length))
    hintTargets = targets; hintLabels = labels; hintIdx = idx; hinting = true; yankMode = true
    // A MODE banner, not a confirmation — "label copies" read as "copied".
    feedbackPill.show(targets.length ? "YANK MODE — press a yellow [letter] · yy = all · esc"
                                     : "YANK MODE — no code/links here · yy = all · esc")
  }
  property string lastCancel: ""
  function cancelHints(why) {
    if (hinting) lastCancel = (why || "unknown") + " @cur=" + cur
    hinting = false; yankMode = false; hintLabels = []; hintTargets = []; hintIdx = -1
  }
  function hintKey(ch) {
    var i = hintLabels.indexOf(ch)
    var t = i >= 0 ? hintTargets[i] : ""
    var wasYank = yankMode, idx = hintIdx
    cancelHints("picked:" + ch)
    if (wasYank) {
      if (t) copyText(t)
      else if (ch === "y") copyText(String(feedCopyTarget(groupedFeed[idx]) || ""))
    } else if (t) Quickshell.execDetached(["xdg-open", t])
  }
  // Qt IGNORES Text.linkColor for MarkdownText (links stay the default dark blue,
  // invisible on the dark card), so colour the link's visible text inline instead.
  // Underline is left to the anchor, so links still read as links.
  readonly property string summaryHex: rail._hex(summaryColor)
  function colorizeLinks(t) {
    var out = String(t || "").replace(/\[([^\]]*)\]\((https?:\/\/[^\s)]+)\)/g,
      function (all, label, url) {
        return "[<font color=\"" + rail.summaryHex + "\"><u>" + label + "</u></font>](" + url + ")"
      })
    // Bare URLs too: Qt autolinks them but paints with the PALETTE link color
    // (near-invisible dark blue on the dark ground), ignoring linkColor — so wrap
    // them into explicit colored markdown links ourselves.
    return out.replace(/(^|[\s])(https?:\/\/[^\s)<>"]+)/g, function (all, pre, url) {
      return pre + "[<font color=\"" + rail.summaryHex + "\"><u>" + url + "</u></font>](" + url + ")"
    })
  }
  // Inline hint badge. Qt's MARKDOWN path passes <font color> through but STRIPS
  // `style` attributes, so an inline background (a real cap) is impossible here —
  // a bracketed accent letter is the strongest marker that survives. mlqs gets
  // true KeyCaps by reserving a transparent gap and mirroring the document in a
  // hidden TextEdit for per-gap pixel rects; that port is the upgrade path.
  // Hints only ever land on the FOCUSED message, whose card is filled with
  // Theme.surface2 — so the badge is measured against THAT, not the normal card.
  // yellow is 5.78:1 on surface2 (orange only 4.28, under AA for small text) and
  // stays distinct from the link hue.
  function _hintBadge(label) {
    return "<font color=\"" + rail._hex(Theme.yellow) + "\"><b>["
         + label + "]</b></font>&#8201;"
  }
  // Pasted-image references ride the prompt as @.heidr-pastes/<file> but should
  // read as attachments, not paths. Markdown strips style attrs (see _hintBadge),
  // so the badge is a colored bold token, numbered per message in paste order —
  // matching the composer chips.
  function badgeAttachments(t) {
    var n = 0
    // Both ref shapes: remote worktree-relative (@.heidr-pastes/…) and local
    // cache-absolute (@/home/…/.cache/heidr-pastes/…).
    return String(t || "").replace(/@?[\w~./-]*heidr-pastes\/([^\s"']+)/g, function (all, file) {
      var stem = String(file).replace(/\.[a-z]+$/, "")
      return "<font color=\"" + rail._hex(Theme.electric) + "\"><b>&#128206;&#8201;" + stem + "</b></font>"
    })
  }
  function _hex(c) {
    function h(v) { var s = Math.round(v * 255).toString(16); return s.length < 2 ? "0" + s : s }
    return "#" + h(c.r) + h(c.g) + h(c.b)
  }
  // Prefix each link with a `label` badge when this row is the hinted one.
  function hintify(t, rowIdx) {
    if (!hinting || rowIdx !== hintIdx) return t
    var n = 0, labels = hintLabels
    return String(t || "").replace(yankMode ? _yankRe() : _linkRe(), function (all) {
      var l = labels[n]; n++
      if (!l) return all
      // A fence must stay at line start — its badge sits on its own line above.
      if (rail.yankMode && all.slice(0, 3) === "```") return rail._hintBadge(l) + "\n\n" + all
      return rail._hintBadge(l) + all
    })
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
  // edits those files via the SSHFS mount, so rewrite box paths to the mount
  // point ($HOME/lovbox/heidr/…). Local sessions (/home/<you>/…) pass through.
  // Remote path → its local mutagen mirror. One entry per remote we sync: the old
  // lovbox rooted at /home/lovable, and the dev VM whose worktrees live under
  // ~<vmuser>/src (vm-wt mirrors those to ~/lovbox/vm). Without the VM entry,
  // live-follow cd'd nvim to a VM-absolute path that does not exist locally, which
  // is why the editor came up on an empty buffer.
  readonly property var _mirrors: [
    { remote: "/home/lovable",
      local: Quickshell.env("HOME") + "/lovbox/heidr" },
    // The VM's worktrees mirror into REAL local git worktrees (…/work/lovable.daphen-<t>),
    // not a bare directory: gitsigns, hunk jumping and the dashboard all need a
    // repository, and a plain mirror has none — mutagen has to skip .git because a
    // worktree's .git is a FILE holding a VM-absolute gitdir.
    { remote: "/home/" + (Quickshell.env("HEIDR_VM_USER") || "david_karlsson_lovable_dev") + "/src/lovable-",
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
    var cwd = ""
    if (agentd) for (var i = 0; i < agentd.sessions.length; i++)
      if (agentd.sessions[i].id === selectedRaw) { cwd = agentd.sessions[i].cwd; break }
    return _isRemote(cwd)
  }
  property string pasteDirFor: {
    var cwd = ""
    if (agentd) for (var i = 0; i < agentd.sessions.length; i++)
      if (agentd.sessions[i].id === selectedRaw) { cwd = agentd.sessions[i].cwd; break }
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
    var cwd = ""
    if (agentd) for (var i = 0; i < agentd.sessions.length; i++)
      if (agentd.sessions[i].id === selectedRaw) { cwd = agentd.sessions[i].cwd; break }
    if (!_isRemote(cwd)) return
    var vmuser = Quickshell.env("HEIDR_VM_USER") || "david_karlsson_lovable_dev"
    // Only the dev VM speaks plain ssh/scp; a lovbox mirror keeps mutagen as its carrier.
    if (cwd.indexOf("/home/" + vmuser + "/") !== 0) return
    var host = Quickshell.env("HEIDR_VM_HOST")
             || ((Quickshell.env("HEIDR_VM") || "dev-heidr-2a39") + ".workstation.lovable.net")
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
  Connections {
    target: rail.agentd
    function onSessionsChanged() {
      if (!rail._landed || !rail.selectedRaw) return
      for (var i = 0; i < rail.agentd.sessions.length; i++) {
        var ss = rail.agentd.sessions[i]
        if (ss.id === rail.selectedRaw) {
          var key = ss.id + "@" + ss.cwd
          if (rail._landedFor && rail._landedFor.indexOf(ss.id + "@") === 0 && rail._landedFor !== key)
            rail.landNvim(ss.id)
          return
        }
      }
    }
  }
  function landNvim(sid) {
    if (!sid || !agentd) return
    var cwd = "", st = ""
    for (var i = 0; i < agentd.sessions.length; i++)
      if (agentd.sessions[i].id === sid) { cwd = agentd.sessions[i].cwd; st = agentd.sessions[i].status || ""; break }
    if (!cwd) return
    _landedFor = sid + "@" + cwd
    // Switching TO a session that is mid-turn lands on its LIVE EDGE — the file it
    // last edited — not the dashboard. The dashboard is for arriving at rest.
    if (st === "streaming" && agentd.lastEditFor(sid) && nvimSock.length) {
      var lcwd0 = rail._localPath(cwd)
      var lp0 = rail._localPath(String(agentd.lastEditFor(sid)))
      if (lp0.charAt(0) !== "/") lp0 = lcwd0 + "/" + lp0
      Quickshell.execDetached(["nvim", "--server", nvimSock, "--remote-expr",
        'isdirectory("' + lcwd0 + '") ? (execute("cd ' + lcwd0 + '") . v:lua.require("heidr").follow_remote("' + lcwd0 + '","' + lp0 + '", v:true)) : ""'])
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
    var repo = Quickshell.env("HOME") + "/work/lovable"
    var dashAt = function (d) { return 'execute(\'lua require("heidr").dashboard("' + d + '")\')' }
    var dash = '((isdirectory("' + cwd + '/.git") || filereadable("' + cwd + '/.git")) ? '
             + dashAt(cwd) + ' : ' + dashAt(repo) + ')'
    // Always the DASHBOARD, never the plan. The dashboard is the session's home — it's
    // where the app, the tickets and the plan are all reachable from — so opening the plan
    // buffer instead dropped you somewhere you then had to navigate out of. Read the plan
    // from the dashboard when you want it.
    var open = dash
    // Guard the cd: a session whose worktree isn't mirrored locally (the VM's main
    // checkout, an unsynced tree) maps to a path that does not exist here, and cd'ing
    // there left nvim on an empty buffer staring at nothing.
    var expr = 'isdirectory("' + cwd + '") ? (execute("cd ' + cwd + '") . ' + open + ') : ""' 
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
    var cwd = ""
    for (var i = 0; i < agentd.sessions.length; i++)
      if (agentd.sessions[i].id === sid) { cwd = agentd.sessions[i].cwd; break }
    if (!cwd || !rail._isRemote(cwd)) return
    var m = String(sid).match(/([a-z]+-\d+)/i)
    if (!m) return
    Quickshell.execDetached([Quickshell.env("HOME") + "/.config/niri/scripts/vm-sync",
                             "--align", m[1]])
  }

  function openInNvim(path) {
    if (!path || !String(path).length) return
    var p = String(path)
    // Resolve worktree-relative paths against the selected session's cwd — nvim's
    // own cwd is the cockpit dir, so a bare "web/…" would open an empty buffer.
    if (p.charAt(0) !== "/" && changesCwd) p = changesCwd + "/" + p
    p = rail._localPath(p)   // box path → local SSHFS mount (no-op for local sessions)
    if (!nvimSock.length) return
    Quickshell.execDetached(["nvim", "--server", nvimSock, "--remote", p])
    rail.focusNvim()
  }
  // Prose blocks of an agent turn (the headline answer).
  function turnProse(items) { return (items || []).filter(x => x.kind === "text") }
  // The pi turn-recap line ("✧ … ; next question/action: …") — coloured sky so
  // the recap reads apart from the body (matches the nvim rail's summary hue).
  function isSummaryLine(l) {
    var s = String(l || "")
    return /^\s*[✦✧⟢⟣✤◆❉]/.test(s) || /\bnext\s+(question|action)\s*:/i.test(s)
  }
  // Thinking blocks — shown inline (the visible thought-process trail).
  function turnThinks(items) { return (items || []).filter(x => x.kind === "think") }
  // Compact one-line summary of a turn's TOOL activity (thinking is shown, not
  // counted): "4 bash · 6 read · edited 3".
  function turnActivitySummary(items) {
    var counts = {}, edits = 0, interrupts = 0, errors = 0
    for (var i = 0; i < (items || []).length; i++) {
      var it = items[i]
      if (it.kind === "text" || it.kind === "think") continue
      else if (it.kind === "edit") edits++
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
    if (edits) parts.push("edited " + edits)
    if (interrupts) parts.push("interrupted")
    if (errors) parts.push(errors === 1 ? "1 error" : errors + " errors")
    return parts.join("  ·  ")
  }
  function turnActivityItems(items) {
    return (items || []).filter(x => x.kind !== "text" && x.kind !== "think" && !(x.kind === "cmd" && x.tool === "info"))
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
  // Coming back from nvim should land where you LEFT (nvim-heidr behaviour): the
  // cursor position survives on its own (it's just `cur`), but insert mode was
  // being force-cleared on every return, so leaving from the composer dumped you
  // back in the roster. Remember it across the blur instead.
  property bool _wasInsert: false
  onFocusedChanged: {
    if (!focused) { _wasInsert = insert; insert = false; return }
    if (_wasInsert) { enterInsert(); return }   // was typing → back into the composer
    insert = false
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

  // HEIDR_DEMO=1 forces the mock showcase (working session + orb, every feed
  // kind, changed files) so all states are visible without a live session.
  readonly property bool demo: Quickshell.env("HEIDR_DEMO") === "1"

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

  function shortName(n) {
    var s = String(n).replace(/^lovable\.daphen-/, "").replace(/^daphen-/, "")
    var m = s.match(/^([a-z]+-\d+)/)
    return m ? m[1] : s
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
  // mcp/asks are the identity electric. Thinking (no tool) idles on electric.
  function actionGlow(sid) {
    agentd ? agentd.curToolGen : 0
    var t = agentd ? agentd.curToolFor(sid) : ""
    if (t === "edit" || t === "write" || t === "create" || t === "str_replace") return Theme.green
    if (t === "bash" || t === "shell") return Theme.orange
    if (t === "read" || t === "grep" || t === "glob" || t === "find" || t === "ls" || t === "ripgrep" || t === "search_files") return Theme.sky
    return Theme.electric
  }
  function dotColor(st) {
    if (st === "streaming") return Theme.green
    if (st === "error")     return Theme.red
    // Everything else is a session doing nothing. Electric read as "look here" on
    // every idle row, which is exactly the wrong signal — reserve colour for state
    // that wants attention.
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
  function _recomputeDefault() {
    if (!live || !agentd || !agentd.settled) { defaultRaw = ""; return }
    if (defaultRaw && liveSessions.some(s => s.name === defaultRaw)) return
    var roots = liveSessions.filter(s => !s.parent)
    var pool = (roots.length ? roots : liveSessions).slice()
    pool.sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
    defaultRaw = pool.length ? pool[0].name : ""
  }
  onLiveSessionsChanged: _recomputeDefault()
  Connections {
    target: rail.agentd
    function onSettledChanged() { rail._recomputeDefault() }
  }
  readonly property string selectedRaw: activeRaw || defaultRaw

  // Pending ask_user question (extension_ui_request) for the selected session.
  // Reactive to agentd.askGen so it clears the instant we answer.
  readonly property var pendingAsk: {
    if (!agentd || !selectedRaw) return null
    agentd.askGen   // reactive dependency
    return agentd.askFor(selectedRaw)
  }
  function answerAsk(payload) { if (agentd && pendingAsk) agentd.answerAsk(selectedRaw, payload) }
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
    if (!pendingAsk) return
    var m = pendingAsk.method
    if (m === "input" || m === "editor") { rail.requestFocus(); Qt.callLater(rail.enterInsert) }
    else rail.exitInsert()   // clears insert AND focuses the rail
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
    var all = liveSessions, children = {}, roots = []
    for (var i = 0; i < all.length; i++) {
      var s = all[i]
      if (s.parent && all.some(x => x.name === s.parent))
        (children[s.parent] = children[s.parent] || []).push(s)
      else roots.push(s)
    }
    // Stable order by name so rows never jump when the daemon reorders on a
    // status change (streaming/idle floats sessions around otherwise).
    var byName = (a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0
    roots.sort(byName)
    for (var key in children) children[key].sort(byName)
    var out = []
    function walk(s, depth, parentCwd) {
      out.push({ name: shortName(s.name), rawName: s.name, idle: stateLabel(s.status),
                 status: s.status, linked: !!s.parent, cwd: s.cwd || "",
                 hasWorktree: /\.daphen-|\/work\//.test(s.cwd || ""),
                 // A devenv slice belongs to a WORKTREE, not to the main checkout. Local
                 // worktrees are <repo>.daphen-<t>, VM ones <repo>-<t>; the plain repo
                 // root (…/work/lovable, …/src/lovable) has none, so a session opened
                 // there — an orchestrator, a one-off — must not claim one.
                 // …and never a CHILD in its parent's worktree: the babysitter/watcher
                 // shares the ticket session's cwd, but the slice belongs to the parent.
                 devenv: /\.daphen-[^/]+$|\/lovable-[^/]+$/.test(s.cwd || "") && s.cwd !== parentCwd,
                 remote: rail._isRemote(s.cwd), scope: s.scope || "",
                 profile: s.profile || "",   // agentd role (…-orchestrator/worker/…)
                 depth: Math.min(depth, 1) })  // one level deep only
      var kids = children[s.name] || []
      for (var j = 0; j < kids.length; j++) walk(kids[j], depth + 1, s.cwd || "")
    }
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
  readonly property bool remoteOffered: Quickshell.env("HEIDR_SCOPE") === "lovable"
  function openNew()  {
    newOpen = true
    newMode = remoteOffered ? "" : "local"
    requestFocus()
    if (!remoteOffered) Qt.callLater(rail.enterInsert)
  }
  function closeNew() { newOpen = false; newMode = ""; exitInsert() }
  function createSession(name) {
    var n = String(name || "").trim()
    if (!n) return
    if (newMode === "remote") {
      vmWt.command = ["vm-wt", n]
      vmWt.running = true
    } else if (agentd) {
      // The launcher exports the mode's home dir: ~/work/lovable in the work cockpit,
      // ~/personal in the private one — a hardcoded lovable path spawned private
      // sessions into the work checkout.
      agentd.send({ type: "spawn", session: n.toLowerCase(),
                    cwd: Quickshell.env("HEIDR_NEW_CWD") || (Quickshell.env("HOME") + "/work/lovable") })
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
  Connections {
    target: rail.agentd
    function onEditSeen(sid, path) {
      if (sid !== rail.selectedRaw || !rail.nvimSock.length) return
      var cwd = ""
      for (var i = 0; i < rail.agentd.sessions.length; i++)
        if (rail.agentd.sessions[i].id === sid) { cwd = rail.agentd.sessions[i].cwd; break }
      if (!cwd) return
      var lcwd = rail._localPath(cwd)
      var p = rail._localPath(String(path))
      if (p.charAt(0) !== "/") p = lcwd + "/" + p     // pi may report worktree-relative
      Quickshell.execDetached(["nvim", "--server", rail.nvimSock, "--remote-expr",
        'v:lua.require("heidr").follow_remote("' + lcwd + '","' + p + '")'])
    }
  }

  // While the selected session is mid-turn, re-pull its transcript on a timer. Without
  // this the chat is frozen from whenever the rail last fetched — most visibly when you
  // open heidr while an agent is already working, which reads as "nothing is happening".
  Timer {
    interval: 5000
    repeat: true
    running: rail.live && rail.featuredStreaming && rail.selectedRaw !== ""
    onTriggered: if (rail.agentd) rail.agentd.refreshEntries(rail.selectedRaw)
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
  function enterInsert() {
    // A blocking confirm/select ask owns the keyboard and HIDES the composer —
    // entering insert would focus an invisible input and strand every key
    // (selecting a session that already had an ask pending hit exactly this).
    if (pendingAsk && !askWantsText) { exitInsert(); return }
    insert = true
    if (newOpen && newMode !== "") newInput.forceActiveFocus()
    else if (askWantsText) askInput.forceActiveFocus()
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
      // Enter on a turn opens/closes its collapsed tool activity ("N bash · …") —
      // copying moved to Y / yank-hints. Same key the activity Loader builds.
      var it = groupedFeed[l]
      if (it) toggleGroupKey("turn-" + (it.key || l))
    }
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
      (insert && !(pendingAsk && !askWantsText)) ? "insert"
    : (pendingAsk && !askWantsText)              ? "ask"
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
    if (e.key === Qt.Key_Escape) { closeNew(); return true }
    if (newMode === "") {
      if (e.key === Qt.Key_L) { newMode = "local";  Qt.callLater(rail.enterInsert); return true }
      if (e.key === Qt.Key_R && remoteOffered) { newMode = "remote"; Qt.callLater(rail.enterInsert); return true }
      return true
    }
    return false
  }

  // A pending question owns its keys: y/n (confirm), 1–9 (select), i (type a
  // reply), esc (cancel), t (cancel + say what you actually think). j/k fall
  // through so the chat still scrolls under the card.
  function keyAsk(e) {
    var pm = pendingAsk.method
    if (e.key === Qt.Key_Escape) { answerAsk({ cancelled: true }); return true }
    if (e.key === Qt.Key_T && !(e.modifiers & Qt.ControlModifier)) {
      answerAsk({ cancelled: true })
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
    // Ctrl+j → jump into the main view; Ctrl+k → back to the roster top.
    if (ctrl && e.key === Qt.Key_J) { cur = (rSize < navTotal) ? rSize : Math.max(0, navTotal - 1); return true }
    if (ctrl && e.key === Qt.Key_K) { cur = 0; return true }
    switch (e.key) {
    case Qt.Key_I:      enterInsert(); return true
    case Qt.Key_Escape:
      // Esc = interrupt, everywhere: abort the open session's turn if it is
      // running; idle keeps the old escape-to-nvim.
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
    case Qt.Key_X:
      // x kills the session under the ROSTER cursor and does nothing anywhere
      // else: interrupting a turn is Esc, and a kill should require aiming.
      if (rail.curSection() === "roster") {
        var row = rail.rosterList[rail.curLocal()]
        if (row && rail.agentd) rail.agentd.stop(row.rawName || row.name)
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
    // Insert: the focused input owns the keyboard — except a blocking confirm/
    // select ask, which hides the composer, so its keys must still land here.
    if (insert && !(pendingAsk && !askWantsText)) return
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
        if (o.text !== undefined && String(o.text).length > 40) out.push(String(o.text))
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
      if (pendingAsk && !(insert && askWantsText)) answerAsk({ confirmed: k === "y" })
    }
    else if (k === "x") {
      if (curSection() === "roster") {
        var row = rosterList[curLocal()]
        if (row && agentd) agentd.stop(row.rawName || row.name)
      }
    }
    else if (k === "yank") startYank()
    else if (k.indexOf("hintkey:") === 0) hintKey(k.slice(8))
    else if (k === "esc") {
      if (featuredStreaming && agentd && selectedRaw) agentd.interrupt(selectedRaw)
      else if (insert) exitInsert()
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
  readonly property var groupedFeed: {
    var f = feed, out = [], cur = null, acts = 0, chunked = false
    for (var i = 0; i < f.length; i++) {
      var it = f[i]
      if (it.kind === "user") {
        if (cur) { out.push(cur); cur = null; acts = 0 }
        chunked = false
        out.push({ kind: "user", text: it.text, mid: it.mid, steered: it.steered === true, key: it.mid || ("i" + i) })
      } else {
        if (!cur) { cur = { kind: "turn", items: [], key: it.mid || ("i" + i), contFrom: chunked }; acts = 0 }
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
    return out
  }

  ColumnLayout {
    anchors { top: parent.top; left: parent.left; right: parent.right; bottom: chin.top }
    anchors.margins: 0
    // The feed ENDS at the sheet's top — no slide-under. Sliding beneath the rounded
    // corners forced the fade to a full-opacity band across the notch zone, and that
    // band smoked the text above the sheet; ending here leaves clean ground behind
    // the corner arcs and lets the fade stay a gentle dissolve.
    anchors.bottomMargin: 0
    spacing: 0

    // Files view — full changed-files list for the selected session.
    ListView {
      id: changesView
      Layout.fillWidth: true
      Layout.leftMargin: 20; Layout.rightMargin: 20
      Layout.fillHeight: rail.view === "files"
      visible: rail.view === "files"
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
    ListView {
      id: feedView
      Layout.fillWidth: true
      Layout.leftMargin: 20; Layout.rightMargin: 20
      Layout.fillHeight: rail.view === "chat"
      visible: rail.view === "chat"
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
      // (`ipc call heidr railGeom` shows it: y jumps by 75 between rows that are 144 tall.)
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
        Component.onCompleted: { opacity = 1; rail.probeCardCreates++ }
        Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }
        property int rowIndex: index
        readonly property real cardHeight: card.height   // for the feedGeom probe
        // Capture the row's turn once: nested Repeaters shadow `model` with their
        // own model property, so model.d is only readable at the delegate root.
        readonly property var turn: model.d
        readonly property bool isUser: turnDel.turn.kind === "user"
        readonly property bool cursor: rail.focused && !rail.insert && rail.cur === rail.rSize + rowIndex

        Rectangle {
          id: card
          anchors { left: parent.left; right: parent.right }
          implicitHeight: cardCol.implicitHeight + 36
          radius: 14
          // Cursor gets a pronounced fill (surface2 pops in both light+dark) plus
          // a strong fg-alpha hairpin — the dsqrd message-cursor grammar.
          color: turnDel.cursor ? Theme.surface2 : (turnDel.isUser ? Theme.surface0 : Theme.surface)
          // Dark: borderless — the bgDim ground separates the fill on its own.
          // Light: surfaces sit too close to the ground, keep the hairline.
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
              Icon {
                name: turnDel.isUser ? "paper-plane-2" : "sparkle-3"
                variantSize: turnDel.isUser ? 12 : 0   // paper-plane-2--glyph--12 for "you"
                width: 16; height: 16; anchors.verticalCenter: parent.verticalCenter
                color: turnDel.isUser ? Theme.orange : Theme.electric
              }
              Text {
                text: turnDel.isUser ? "you" : "agent"
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

            // User message body.
            Text {
              visible: turnDel.isUser
              width: cardCol.width
              text: turnDel.isUser ? rail.colorizeLinks(rail.hintify(rail.badgeAttachments(turnDel.turn.text), turnDel.rowIndex)) : ""
              color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
              linkColor: rail.summaryColor   // links match the summary hue (sky is too harsh); underline keeps them scannable
              wrapMode: Text.WordWrap; textFormat: Text.MarkdownText
              onLinkActivated: (u) => Quickshell.execDetached(["xdg-open", u])
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
                width: cardCol.width
                sourceComponent: thinkRow
                opacity: 0
                Component.onCompleted: opacity = 1
                Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutQuad } }
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
                property int rowIndex: turnDel.rowIndex   // so `f` hints can target this row
                sourceComponent: proseRow
              }
            }

            // Compact activity summary — "4 bash · 6 read · edited 3", expandable.
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
              // The turn that is CURRENTLY working expands by default, so you can watch
              // which tools it's reaching for; finished turns stay condensed to the
              // one-line summary. An explicit tap always wins over the default.
              property bool liveTurn: turnDel.rowIndex >= rail.fSize - 1 && rail.featuredStreaming
              property bool expanded: (ekey in rail.expandedGroups)
                                      ? rail.expandedGroups[ekey] === true
                                      : liveTurn
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
    height: chinCol.implicitHeight + 28 + radius   // 14 top pad + 14 visible bottom pad
    color: Theme.surface0

    ColumnLayout {
      id: chinCol
      // Bottom-anchored so the composer + hints stay put and the roster grows UPWARD
      // when it expands (the sheet's top edge rises; the input never moves).
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 20; rightMargin: 20; bottomMargin: 14 + chin.radius }
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
        implicitHeight: (rail.rosterExpanded ? rosterInner.implicitHeight : glanceCol.implicitHeight) + 8
        Behavior on implicitHeight { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

        // Collapsed glance: active session name on the left (the roster row grammar),
        // status dots for the OTHER sessions on the right.
        Item {
          id: glanceCol
          anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 4 }
          // Tall enough for whatever sits in the name row (the working orb is 44px) —
          // a fixed 32 clipped the orb against the sheet's edges.
          implicitHeight: Math.max(32, glanceName.implicitHeight + 4)
          opacity: rail.rosterExpanded ? 0 : 1
          visible: opacity > 0.01
          Behavior on opacity { NumberAnimation { duration: 220 } }
          Row {
            id: glanceName
            anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
            spacing: 9
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: (rail.shortName(rail.selectedRaw) || "lovable").toUpperCase()
              color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: rail.fsName; font.bold: true
            }
            // The "thinking" signifier lives HERE now (the floating pill is gone):
            // same orb grammar as the expanded rows.
            ThinkingOrb {
              anchors.verticalCenter: parent.verticalCenter
              // The one "thinking" signifier since the floating pill left — big
              // enough to read from the corner of the eye.
              width: 44; height: 44
              running: rail.featuredStreaming
              nodes: 16
              glow: rail.actionGlow(rail.selectedRaw)
            }
          }
          Row {
            anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
            spacing: 12
            Repeater {
              // rosterModel, NOT a filtered array: the array's identity changed on every
              // roster push, so every dot (and running spinner) was destroyed and rebuilt
              // several times a second while anything streamed — the "blinking dots".
              // Rows update in place via setProperty; the selected session's slot hides.
              model: rosterModel
              Item {
                readonly property var md: model.d
                readonly property bool self: (md.rawName || md.name) === rail.selectedRaw
                visible: !self
                width: 12; height: 12
                Component.onCompleted: rail.probeDotCreates++
                Spinner {
                  anchors.centerIn: parent; visible: parent.visible && md.status === "streaming"
                  running: visible; color: Theme.green; dotSize: 2.0
                }
                Rectangle {
                  anchors.centerIn: parent; visible: parent.visible && md.status !== "streaming"
                  width: 7; height: 7; radius: 3.5; color: rail.dotColor(md.status)
                }
              }
            }
          }
        }

        ColumnLayout {
          id: rosterInner
          opacity: rail.rosterExpanded ? 1 : 0
          visible: opacity > 0.01
          Behavior on opacity { NumberAnimation { duration: 220 } }
          anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 4 }
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
              color: cursor ? Theme.fg
                   : selected ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.08)
                   : hov.hovered ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.04) : "transparent"
              HoverHandler { id: hov }
              // Collapsed: index doesn't map to the full list → just focus/expand.
              TapHandler { onTapped: rail.rosterExpanded ? rail.clickAt(index) : rail.requestFocus() }
              RowLayout {
                anchors { fill: parent; leftMargin: 14 + (modelData.depth || 0) * 20; rightMargin: 14 }
                spacing: 8
                // Nesting connector for spawned subagents.
                Text {
                  visible: (modelData.depth || 0) > 0
                  text: "↳"; color: sessRow.cursor ? Theme.bg : Theme.fg_muted
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
                  color: sessRow.cursor ? Theme.bg : Theme.fg
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
                  color: sessRow.cursor ? Theme.bg : Theme.fg
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
                  color: sessRow.cursor ? Theme.bg : Theme.fg_muted
                }
                // Spinner immediately right of the name. The slot is reserved even when idle
                // so nothing shifts as a session starts or stops working. 20px is free (the
                // row is a fixed 40px tall) and 20 is what it takes to LOOK bigger: the box
                // draws a sphere ~0.83 of its size, so a 16px box was only ~13px of visible
                // mesh next to 14px icons.
                Item {
                  Layout.preferredWidth: 20; Layout.preferredHeight: 20
                  Layout.alignment: Qt.AlignVCenter
                  ThinkingOrb {
                    anchors.fill: parent
                    running: sessRow.streaming
                    // Pinned to 13 rather than letting the size rule pick 15 for 16px — 13 is
                    // the density that was judged right, and this keeps it while growing.
                    nodes: 13
                    // Electric, not muted: the one thing in the row that should catch the eye.
                    glow: sessRow.cursor ? Theme.bg : rail.actionGlow(modelData.rawName || modelData.name)
                  }
                }
                Item { Layout.fillWidth: true }   // pushes status + devenv to the right edge
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
                Text {
                  text: sessRow.hasAsk ? "" : (modelData.state || modelData.idle || "")
                  // Sub-agents (linked rows) carry no status word at all — the orb says
                  // "working", and an idle watcher needs no label to say it's waiting.
                  visible: !modelData.linked
                  Layout.preferredWidth: visible ? 74 : 0; horizontalAlignment: Text.AlignRight
                  Layout.alignment: Qt.AlignVCenter
                  // One muted colour for every state: the orb by the name already says
                  // "working", so colouring the word too was saying it twice.
                  color: sessRow.cursor ? Theme.bg : Theme.fg_muted
                  font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
                }
                Icon {
                  // Only MARKED when the session actually has a devenv slice (it used to go
                  // green for every top-level session, so a main-checkout session looked
                  // like it owned a slice it never had) — but the slot is always reserved,
                  // via opacity rather than visible, so the status text stays on one
                  // vertical line down the roster instead of shifting per row.
                  opacity: modelData.devenv === true ? 1 : 0
                  name: "plug-2"; width: 15; height: 15
                  Layout.preferredWidth: 15; Layout.preferredHeight: 15   // equal dims → no squish
                  Layout.alignment: Qt.AlignVCenter
                  color: sessRow.cursor ? Theme.bg : Theme.green
                }
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
        Row {
          anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
          spacing: 8
          Text {
            text: "⏳"; color: Theme.fg_muted
            font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
          }
          Text {
            readonly property int qn: rail.agentd ? rail.agentd.queuedFor(rail.selectedRaw) : 0
            text: qn + " queued — sends when the turn ends: “"
                  + (rail.agentd ? rail.agentd.queuedFirst(rail.selectedRaw) : "").slice(0, 60) + "”"
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
          text: "needs your input"
          color: Theme.orange; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta; font.bold: true
        }
        Text {
          visible: text.length > 0; width: parent.width; wrapMode: Text.Wrap
          text: askCard.ask ? (askCard.ask.title || "") : ""
          color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
        }
        Text {
          visible: text.length > 0; width: parent.width; wrapMode: Text.Wrap
          text: askCard.ask ? (askCard.ask.message || "") : ""
          color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
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
            Text { text: "yes"; color: Theme.green; font.family: Theme.fontFamily; font.pixelSize: rail.fsBody; anchors.verticalCenter: parent.verticalCenter } }
          Row { spacing: 8; KeyCap { text: "n"; anchors.verticalCenter: parent.verticalCenter }
            Text { text: "no"; color: Theme.red; font.family: Theme.fontFamily; font.pixelSize: rail.fsBody; anchors.verticalCenter: parent.verticalCenter } }
          // Neither yes nor no: release the agent from the question and open the composer,
          // for the common case where the question itself is the thing worth discussing.
          Row { spacing: 8; KeyCap { text: "t"; anchors.verticalCenter: parent.verticalCenter }
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
          text: (askCard.ask && askCard.ask.method === "select")
                ? "press a number · t to talk · esc cancels" : "t to talk · esc cancels"
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
            text: "new session"; color: Theme.electric
            font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta; font.bold: true
          }
          Row {
            spacing: 20
            visible: rail.newMode === ""
            Row { spacing: 8; KeyCap { text: "l"; anchors.verticalCenter: parent.verticalCenter }
              Text { text: "local — a session here"; color: Theme.fg
                     font.family: Theme.fontFamily; font.pixelSize: rail.fsBody; anchors.verticalCenter: parent.verticalCenter } }
            Row { visible: rail.remoteOffered
              spacing: 8; KeyCap { text: "r"; anchors.verticalCenter: parent.verticalCenter }
              Text { text: "remote — worktree on the VM"; color: Theme.fg
                     font.family: Theme.fontFamily; font.pixelSize: rail.fsBody; anchors.verticalCenter: parent.verticalCenter } }
          }
          Rectangle {
            width: newCol.width
            visible: rail.newMode !== ""
            implicitHeight: 44; height: implicitHeight
            radius: 10
            color: Theme.surface0
            border.color: rail.insert ? Theme.electric : Theme.hairline
            border.width: 1
            RowLayout {
              anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
              spacing: 8
              Icon { name: "chevron-right"; width: 14; height: 14; color: Theme.electric }
              TextInput {
                id: newInput
                Layout.fillWidth: true
                color: Theme.fg
                font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
                clip: true
                verticalAlignment: TextInput.AlignVCenter
                cursorDelegate: Rectangle { width: 2; radius: 1; color: Theme.cursor; opacity: newInput.cursorVisible ? 1 : 0 }
                onAccepted: { rail.createSession(text); text = "" }
                Keys.onPressed: (e) => {
                  if (e.key === Qt.Key_Escape) { rail.closeNew(); e.accepted = true }
                }
              }
            }
          }
          Text {
            text: rail.newMode === "remote" ? "ticket id, e.g. EVERY-2739 · esc cancels"
                : rail.newMode === "local"  ? "session name · esc cancels"
                : "esc cancels"
            color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
          }
        }
      }

      // Composer — real text input (i to enter, Esc/Ctrl+h to leave). Hidden while an
      // ask is pending: the question TAKES OVER the input rather than floating above a
      // composer that still looks ready for an unrelated message.
      Rectangle {
        Layout.fillWidth: true
        visible: !rail.pendingAsk && !rail.newOpen
        // Grows with the text up to ~3 lines (slqs Composer pattern); beyond that the
        // Flickable scrolls the caret into view.
        implicitHeight: Math.max(52, Math.min(composerInput.implicitHeight + 30, 94))
        radius: Math.min(height / 2, 26)   // pill at one line, rounded card when grown
        color: Theme.surface0
        border.color: rail.insert ? Theme.electric : Theme.hairline
        border.width: 1
        RowLayout {
          anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
          spacing: 8
          Icon {
            name: "chevron-right"; width: 14; height: 14; color: Theme.electric
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
              var pa = rail.pendingAsk
              if (pa && (pa.method === "input" || pa.method === "editor")) {
                if (text.trim().length) rail.answerAsk({ value: text })
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
                if (rail.featuredStreaming && rail.agentd && rail.selectedRaw) rail.agentd.interrupt(rail.selectedRaw)
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
              else if (ctrl && e.key === Qt.Key_H) { rail.exitInsert(); rail.focusNvim(); e.accepted = true }
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
        spacing: 6
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
              return [{ k: "j/k", l: "move" }, { k: "⏎", l: "open" }, { k: "n", l: "new" },
                      { k: "x", l: "kill" }, { k: "C-t", l: "collapse" }, { k: "i", l: "type" },
                      { k: "h", l: "nvim" }]
            }
            return [
              { k: "j/k", l: "move" },
              { k: "⇥",   l: rail.view === "files" ? "chat" : "files" },
              { k: "⏎",   l: rail.view === "files" ? "open" : "copy" },
              { k: "f",   l: rail.hinting ? "pick" : "links" },
              { k: "i",   l: "type" },
              { k: "h",   l: "nvim" }
            ].concat(rail.featuredStreaming ? [{ k: "esc", l: "interrupt" }] : [])
          }
          RowLayout {
            spacing: 4
            KeyCap { small: true; text: modelData.k }
            CapLabel { text: modelData.l }
            Item { width: 4 }
          }
        }
      }
    }
  }

  // Slash-command palette. Same shape as the family's inline autocomplete
  // (slk-gui-proto/Autocomplete.qml): a fixed-width card floating above the chin,
  // bg_alt on a hairline, 32px rows, fg-tinted selection with a hairpin border —
  // Theme.selection is near-invisible on the light popup ground.
  Rectangle {
    id: slashPalette
    readonly property int w: 340
    visible: rail.slashOpen
    anchors { left: parent.left; bottom: chin.top; leftMargin: 20; bottomMargin: 6 }
    width: Math.min(w, parent.width - 40)
    height: visible ? Math.min(slashList.contentHeight + 8, 248) : 0
    color: Theme.bg_alt
    radius: Theme.radius !== undefined ? Theme.radius : 10
    border.color: Theme.hairline
    border.width: 1
    z: 12
    ListView {
      id: slashList
      anchors.fill: parent; anchors.margins: 4; clip: true
      model: rail.commandMatches
      currentIndex: Math.max(0, Math.min(rail.slashCur, rail.commandMatches.length - 1))
      highlightFollowsCurrentItem: false
      interactive: contentHeight > height
      boundsBehavior: Flickable.StopAtBounds
      onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
      delegate: Rectangle {
        id: slashRow
        required property var modelData
        required property int index
        readonly property bool sel: index === slashList.currentIndex
        readonly property bool isSkill: String(modelData).indexOf("skill:") === 0
        width: slashList.width; height: 32
        radius: 9
        color: sel ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.08)
             : chov.hovered ? Theme.hover : "transparent"
        border.width: 1
        border.color: sel ? Theme.hairline : "transparent"
        Row {
          anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 9
          Item {
            width: 20; height: 20; anchors.verticalCenter: parent.verticalCenter
            Icon {
              anchors.centerIn: parent
              name: slashRow.isSkill ? "puzzle-piece" : "bolt-lightning"
              width: 14; height: 14
              color: slashRow.sel ? Theme.fg : Theme.fg_muted
            }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "/" + modelData
            color: slashRow.sel ? Theme.fg : Theme.fg_secondary
            font.family: Theme.fontFamily; font.pixelSize: 14
          }
        }
        HoverHandler { id: chov }
        TapHandler { onTapped: { rail.slashCur = slashRow.index; rail.acceptSlash(); composerInput.forceActiveFocus() } }
      }
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
    id: activityRow
    // Collapsed one-liner of a turn's tool activity; tap to expand the full list.
    Column {
      id: actCol
      width: parent ? parent.width : 400
      spacing: 9
      Row {
        spacing: 7
        Icon { name: expanded ? "chevron-down" : "chevron-right"; width: 12; height: 12; color: Theme.fg_muted; anchors.verticalCenter: parent.verticalCenter }
        Text {
          text: summary; color: Theme.fg_muted
          font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
          anchors.verticalCenter: parent.verticalCenter
        }
        TapHandler { onTapped: rail.toggleGroupKey(ekey) }
      }
      Repeater {
        // An INT model, not the array: an array-model Repeater destroys and recreates
        // EVERY row when the array identity changes — which is every stream update on
        // the auto-expanded live turn, i.e. the chat "blinking". With a count model,
        // growth instantiates only the new indexes and existing rows rebind in place.
        model: expanded ? items.length : 0
        Loader {
          width: actCol.width
          Component.onCompleted: rail.probeActCreates++
          property var entry: items[index]
          property string gkey: ekey + "-" + index
          property bool expanded: rail.expandedGroups[gkey] === true
          sourceComponent: {
            var k = (entry || {}).kind
            if (k === "edit")  return editRow
            if (k === "think") return thinkRow
            if (k === "group") return groupRow
            return cmdRow
          }
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
          text: entry.text + (cmdCol.isFailed ? "  — failed" : "")
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
    id: proseRow
    // Agent prose inside the turn card — borderless markdown, the card provides
    // the surface. The trailing ✧ recap line(s) split out into sky so the
    // "what I did / next question" summary reads apart from the body.
    Column {
      id: proseCol
      width: parent ? parent.width : 400
      spacing: 14   // clear gap between the body and the ✧ recap line
      readonly property var _lines: String(entry.text || "").split("\n")
      readonly property string _body: _lines.filter(l => !rail.isSummaryLine(l)).join("\n").trim()
      readonly property string _summary: _lines.filter(l => rail.isSummaryLine(l)).join("\n").trim()
      Text {
        visible: proseCol._body.length > 0
        width: parent.width
        text: rail.colorizeLinks(rail.hintify(rail.badgeAttachments(proseCol._body), rowIndex)); color: Theme.fg
        linkColor: rail.summaryColor   // links match the summary hue; underline keeps them scannable
        font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
        wrapMode: Text.WordWrap; lineHeight: 1.35
        textFormat: Text.MarkdownText   // **bold**, `code`, lists — like the old rail
        onLinkActivated: (u) => Quickshell.execDetached(["xdg-open", u])
      }
      Text {
        visible: proseCol._summary.length > 0
        width: parent.width
        text: rail.colorizeLinks(rail.badgeAttachments(proseCol._summary)); color: rail.summaryColor
        linkColor: rail.summaryColor   // links match the summary hue (sky is too harsh); underline keeps them scannable
        font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
        wrapMode: Text.WordWrap; lineHeight: 1.35
        textFormat: Text.MarkdownText
        onLinkActivated: (u) => Quickshell.execDetached(["xdg-open", u])
      }
    }
  }
  Component {
    id: editRow
    RowLayout {
      spacing: 8
      Icon { name: "paintbrush"; width: 13; height: 13; color: Theme.fg_muted; Layout.alignment: Qt.AlignVCenter }
      Text { text: entry.file; color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: rail.fsBody; font.bold: true; elide: Text.ElideMiddle; Layout.fillWidth: true }
      // Diff stats only when known (live edits); transcript edits carry none.
      Text { visible: (entry.add + entry.del) > 0; text: "+" + entry.add; color: Theme.green; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta }
      Text { visible: (entry.add + entry.del) > 0; text: "-" + entry.del; color: Theme.red; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta }
    }
  }
}

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import QsLib

// The agent rail: roster (from agentd) + activity feed + composer.
// Vim nav (dsqrd model): j/k move the roster cursor, Enter selects the session
// (drives feed + composer target), i enters the composer, Esc/Ctrl+h/h leave to nvim.
Item {
  id: rail

  property var agentd: null
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
    cur = 0
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
  property bool insert: false
  property bool pinBottom: true   // chat follows new messages unless you scroll up
  // Hands off after ANY user scroll: while this is running, no auto-positioning
  // (pinTimer / bottomSettle / countChanged / feedDebounce) touches contentY.
  // Several of those fire on a 33-120ms cadence and were fighting the wheel, so
  // the feed felt locked. One guard makes the user's gesture always win.
  // Exactly ONE thing may drive the viewport at a time:
  //   followMode = true  → bottom-anchored stream follow (pinTimer), range OFF
  //   followMode = false → the cursor drives it (native ApplyRange), no timers
  // They contradict each other: ApplyRange pulls the CURRENT item's TOP into view,
  // so on a tall growing last card it scrolled UP while the pin timer pulled DOWN.
  readonly property bool followMode: view === "chat" && pinBottom && featuredStreaming
  readonly property bool scrollGuarded: scrollGuard.running
  Timer { id: scrollGuard; interval: 700 }
  function noteUserScroll() { scrollGuard.restart() }
  property string activeRaw: ""
  // Roster starts expanded and stays however you leave it — Ctrl+t toggles the
  // full list vs the single-row glance, and the choice persists across focus
  // changes (no auto-collapse on blur).
  property var rosterOverride: true   // true = expanded (default), false = collapsed glance
  readonly property bool rosterExpanded: rosterOverride !== null ? rosterOverride : focused

  function copyText(s) { if (s && s.length) Quickshell.execDetached(["wl-copy", "--", String(s)]) }

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
  function cancelHints() { hinting = false; hintLabels = []; hintTargets = []; hintIdx = -1 }
  function hintKey(ch) {
    var i = hintLabels.indexOf(ch)
    var url = i >= 0 ? hintTargets[i] : ""
    cancelHints()
    if (url) Quickshell.execDetached(["xdg-open", url])
  }
  // Qt IGNORES Text.linkColor for MarkdownText (links stay the default dark blue,
  // invisible on the dark card), so colour the link's visible text inline instead.
  // Underline is left to the anchor, so links still read as links.
  readonly property string summaryHex: rail._hex(summaryColor)
  function colorizeLinks(t) {
    return String(t || "").replace(/\[([^\]]*)\]\((https?:\/\/[^\s)]+)\)/g,
      function (all, label, url) {
        return "[<font color=\"" + rail.summaryHex + "\"><u>" + label + "</u></font>](" + url + ")"
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
  function _hex(c) {
    function h(v) { var s = Math.round(v * 255).toString(16); return s.length < 2 ? "0" + s : s }
    return "#" + h(c.r) + h(c.g) + h(c.b)
  }
  // Prefix each link with a `label` badge when this row is the hinted one.
  function hintify(t, rowIdx) {
    if (!hinting || rowIdx !== hintIdx) return t
    var n = 0, labels = hintLabels
    return String(t || "").replace(_linkRe(), function (all) {
      var l = labels[n]; n++
      return l ? (rail._hintBadge(l) + all) : all
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
    { remote: "/home/" + (Quickshell.env("HEIDR_VM_USER") || "david_karlsson_lovable_dev") + "/src",
      local: Quickshell.env("HOME") + "/lovbox/vm" }
  ]
  function _localPath(p) {
    var s = String(p || "")
    for (var i = 0; i < _mirrors.length; i++) {
      var m = _mirrors[i]
      if (s === m.remote) return m.local
      if (s.indexOf(m.remote + "/") === 0) return m.local + s.substring(m.remote.length)
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
      if (s.indexOf(m.local + "/") === 0) return m.remote + s.substring(m.local.length)
    }
    return s
  }
  // ── image paste ─────────────────────────────────────────────────────────────
  // pi takes images as `@path` references in the prompt, so a pasted image becomes
  // a file plus an @mention. The file is written into the SELECTED SESSION's cwd
  // (via the mirror for remote work) so mutagen carries it to the box and pi can
  // actually open it — a local /tmp path would not exist over there.
  property var pastedImages: []   // filenames pasted this session, for the strip below
  property string pasteDirFor: {
    var cwd = ""
    if (agentd) for (var i = 0; i < agentd.sessions.length; i++)
      if (agentd.sessions[i].id === selectedRaw) { cwd = agentd.sessions[i].cwd; break }
    return (cwd ? rail._localPath(cwd) : Quickshell.env("HOME")) + "/.heidr-pastes"
  }
  Process {
    id: pasteProc
    stdout: StdioCollector {
      onStreamFinished: {
        var out = String(this.text || "").trim()
        if (!out || out === "NOIMAGE") { composerInput.paste(); return }   // no image → normal text paste
        var ref = "@.heidr-pastes/" + out + " "
        composerInput.insert(composerInput.cursorPosition, ref)
        rail.pastedImages = rail.pastedImages.concat([out])   // for the thumbnail strip
      }
    }
  }
  function pasteImage() {
    // One shell pass: detect an image flavour, write it, print the path (or NOIMAGE).
    pasteProc.running = false
    pasteProc.command = ["sh", "-c",
      'd=' + JSON.stringify(rail.pasteDirFor) + '; mkdir -p "$d" || exit 0; ' +
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

  function landNvim(sid) {
    if (!sid || !agentd) return
    var cwd = ""
    for (var i = 0; i < agentd.sessions.length; i++)
      if (agentd.sessions[i].id === sid) { cwd = agentd.sessions[i].cwd; break }
    if (!cwd) return
    cwd = rail._localPath(cwd)   // box path → local mutagen mirror (no-op for local sessions)
    // Plan location depends on where the session lives: local work uses the vault,
    // a lovbox session has no vault so plan-ticket writes <worktree>/.plans/.
    // Build a vimscript chain that prefers the worktree plan, then the vault, then
    // the session dashboard — filereadable() runs inside nvim, which is the only
    // side that can actually test the paths.
    var m = String(sid).match(/every-(\d+)/i)
    var dash = 'execute(\'lua require("heidr").dashboard("' + cwd + '")\')'
    var open = dash
    if (m) {
      var key = "EVERY-" + m[1]
      var wtPlan    = cwd + "/.plans/" + key + ".md"
      var vaultPlan = Quickshell.env("HOME") + "/personal/notes/storage/plans/" + key + ".md"
      open = '(filereadable("' + wtPlan + '") ? execute("edit ' + wtPlan + '")'
           + ' : (filereadable("' + vaultPlan + '") ? execute("edit ' + vaultPlan + '") : ' + dash + '))'
    }
    var expr = 'execute("cd ' + cwd + '") . ' + open
    var sock = Quickshell.env("XDG_RUNTIME_DIR") + "/heidr-nvim.sock"
    Quickshell.execDetached(["nvim", "--server", sock, "--remote-expr", expr])
  }

  function openInNvim(path) {
    if (!path || !String(path).length) return
    var p = String(path)
    // Resolve worktree-relative paths against the selected session's cwd — nvim's
    // own cwd is the cockpit dir, so a bare "web/…" would open an empty buffer.
    if (p.charAt(0) !== "/" && changesCwd) p = changesCwd + "/" + p
    p = rail._localPath(p)   // box path → local SSHFS mount (no-op for local sessions)
    var sock = Quickshell.env("XDG_RUNTIME_DIR") + "/heidr-nvim.sock"
    Quickshell.execDetached(["nvim", "--server", sock, "--remote", p])
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
    var counts = {}, edits = 0
    for (var i = 0; i < (items || []).length; i++) {
      var it = items[i]
      if (it.kind === "text" || it.kind === "think") continue
      else if (it.kind === "edit") edits++
      else if (it.kind === "group") counts[it.tool] = (counts[it.tool] || 0) + (it.cmds ? it.cmds.length : 1)
      else if (it.kind === "cmd") counts[it.tool] = (counts[it.tool] || 0) + 1
    }
    var parts = []
    for (var k in counts) parts.push(counts[k] + " " + k)
    if (edits) parts.push("edited " + edits)
    return parts.join("  ·  ")
  }
  function turnActivityItems(items) { return (items || []).filter(x => x.kind !== "text" && x.kind !== "think") }

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
  function dotColor(st) {
    if (st === "streaming") return Theme.green
    if (st === "error")     return Theme.red
    // Everything else is a session doing nothing. Electric read as "look here" on
    // every idle row, which is exactly the wrong signal — reserve colour for state
    // that wants attention.
    return Theme.fg_muted
  }
  function toolIcon(tool) {
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

  readonly property var featured: {
    if (!live) return mockFeatured
    var arr = liveSessions.filter(s => s.name === selectedRaw)
    var f = arr.length ? arr[0] : liveSessions[0]
    // No sessions at all (daemon up but idle, or the tunnel dropped) — everything
    // downstream reads .name, so hand back a placeholder rather than undefined.
    if (!f) return { name: daemonUp ? "no sessions" : "disconnected", rawName: "", state: "", status: "idle" }
    return { name: shortName(f.name), rawName: f.name, state: stateLabel(f.status), status: f.status }
  }
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
    function walk(s, depth) {
      out.push({ name: shortName(s.name), rawName: s.name, idle: stateLabel(s.status),
                 status: s.status, linked: !!s.parent, cwd: s.cwd || "",
                 hasWorktree: /\.daphen-|\/work\//.test(s.cwd || ""),
                 remote: rail._isRemote(s.cwd), scope: s.scope || "",
                 depth: Math.min(depth, 1) })  // one level deep only
      var kids = children[s.name] || []
      for (var j = 0; j < kids.length; j++) walk(kids[j], depth + 1)
    }
    for (var r = 0; r < roots.length; r++) walk(roots[r], 0)
    return out
  }
  property bool _wantBottom: false   // scroll chat to bottom once the new session's feed loads
  // A send needs to land on the new row too, but WITHOUT bottomSettle: that timer
  // re-pins 9x over ~540ms to survive async delegate sizing on first load, and on a
  // send the rows are already sized, so those re-pins were visible as the
  // "blinks only on the first message" flicker.
  property bool _sendPin: false
  onSelectedRawChanged: {
    _feedReset = true
    Qt.callLater(rail.syncFeedModel)
    pinBottom = true
    _wantBottom = true
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
  // Per-group expand state, keyed by feed index (resets on transcript refresh).
  property var expandedGroups: ({})
  function toggleGroup(i) {
    var e = Object.assign({}, expandedGroups)
    e[i] = !e[i]
    expandedGroups = e
  }
  function toggleGroupKey(k) { toggleGroup(k) }   // string-keyed groups (turn activity)
  function enterInsert() { insert = true; composerInput.forceActiveFocus() }
  function exitInsert()  { insert = false; composerInput.focus = false; rail.forceActiveFocus() }

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
      if (rSize < navTotal) cur = rSize    // selecting a session drops you into its chat
      return
    }
    if (view === "files") {
      var cf = changesList[l]
      if (cf) openInNvim(cf.path)
    } else {
      var it = groupedFeed[l]
      copyText(feedCopyTarget(it))   // Enter on a turn copies its text
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

  Keys.onPressed: (e) => {
    if (insert) return
    // Link-hint mode owns the keyboard while active: a label letter opens its
    // link, Esc (or any non-label key) drops the hints — mlqs's `f` semantics.
    if (hinting) {
      if (e.key === Qt.Key_Escape) { cancelHints(); e.accepted = true; return }
      if (e.text && /^[a-z]$/.test(e.text)) { hintKey(e.text); e.accepted = true; return }
      cancelHints()   // fall through: the key does its normal thing
    }
    // A pending question owns the keyboard: y/n (confirm), 1–9 (select),
    // i (type a reply for input/editor), esc (cancel). j/k still scroll.
    if (pendingAsk) {
      var pm = pendingAsk.method
      if (e.key === Qt.Key_Escape) { answerAsk({ cancelled: true }); e.accepted = true; return }
      if (pm === "confirm") {
        if (e.key === Qt.Key_Y) { answerAsk({ confirmed: true });  e.accepted = true; return }
        if (e.key === Qt.Key_N) { answerAsk({ confirmed: false }); e.accepted = true; return }
      } else if (pm === "select" && pendingAsk.options) {
        var d = e.key - Qt.Key_0
        if (d >= 1 && d <= Math.min(9, pendingAsk.options.length)) { answerAsk({ value: pendingAsk.options[d - 1] }); e.accepted = true; return }
      } else if (pm === "input" || pm === "editor") {
        if (e.key === Qt.Key_I) { enterInsert(); e.accepted = true; return }
      }
    }
    var ctrl = (e.modifiers & Qt.ControlModifier)
    // Ctrl+j → jump into the main view (chat/files); Ctrl+k → back to roster top.
    if (ctrl && e.key === Qt.Key_J) { cur = (rSize < navTotal) ? rSize : Math.max(0, navTotal - 1); e.accepted = true; return }
    if (ctrl && e.key === Qt.Key_K) { cur = 0; e.accepted = true; return }
    if (ctrl && e.key === Qt.Key_T) { rosterOverride = !rosterExpanded; e.accepted = true; return }
    if (e.key === Qt.Key_I)      { enterInsert(); e.accepted = true }
    else if (e.key === Qt.Key_H || e.key === Qt.Key_Escape) { rail.focusNvim(); e.accepted = true }
    else if (e.key === Qt.Key_J)  { rail.moveDown(); e.accepted = true }
    else if (e.key === Qt.Key_K)  { rail.moveUp(); e.accepted = true }
    else if (e.key === Qt.Key_G)  { cur = (e.modifiers & Qt.ShiftModifier) ? navTotal - 1 : 0; e.accepted = true }
    else if (e.key === Qt.Key_Y)  { var it = curItem(); if (it) rail.copyText(rail.feedCopyTarget(it)); e.accepted = true }
    else if (e.key === Qt.Key_F)  { rail.startHints(); e.accepted = true }   // vimium-style link hints
    else if (e.key === Qt.Key_X)  {                                          // stop the current turn
      if (rail.agentd && rail.selectedRaw) rail.agentd.stop(rail.selectedRaw)
      e.accepted = true
    }
    else if (e.key === Qt.Key_O || e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { activateCur(); e.accepted = true }
  }
  // A feed refresh (stream update / reload) can shrink navTotal below cur, so
  // the cursor points past the last message and nothing highlights. Re-clamp.
  onNavTotalChanged: if (cur > navTotal - 1) cur = Math.max(0, navTotal - 1)

  // Cursor moves only set state — feedView's native highlight range does the
  // scrolling (see currentIndex / preferredHighlightBegin|End there).
  onCurChanged: {
    pinBottom = (cur >= navTotal - 1)   // at the last item → follow new messages
    if (view === "files" && cur >= rSize) changesView.positionViewAtIndex(cur - rSize, ListView.Contain)
    // ApplyRange only guarantees the current item's TOP sits inside the range, so
    // landing on the LAST card left its bottom (and the footer pad) below the fold.
    // Bottom-align that one case explicitly — "j to the last message" should mean
    // the end of the feed. Deferred so the row's height is settled first.
    if (view === "chat" && cur >= navTotal - 1 && navTotal > rSize)
      Qt.callLater(feedView.positionViewAtEnd)
    // With the range disabled during streaming, a deliberate cursor move still needs
    // to bring its row into view — but ONCE, not as a standing constraint.
    else if (view === "chat" && cur >= rSize && featuredStreaming)
      Qt.callLater(function () { feedView.positionViewAtIndex(rail.cur - rail.rSize, ListView.Contain) })
  }
  // subtle focus accent on the left edge (no full ring)
  Rectangle {
    width: 2; height: parent.height; anchors.left: parent.left
    color: Theme.electric; opacity: rail.focused ? 0.5 : 0; z: 10
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
  function syncFeedModel() {
    var arr = groupedFeed
    if (_feedReset || arr.length < feedModel.count) {
      _feedReset = false
      feedModel.clear()
      for (var a = 0; a < arr.length; a++) feedModel.append({ d: arr[a], sig: _turnSig(arr[a]) })
      return
    }
    for (var i = 0; i < arr.length; i++) {
      var sig = _turnSig(arr[i])
      if (i < feedModel.count) {
        // setProperty, NOT set(): set() REPLACES the element and rebuilds that row's
        // delegate. The streaming row fills the viewport, so rebuilding it 8x/sec
        // still read as the whole chat blinking. setProperty mutates the role, so the
        // delegate survives and only its bindings re-evaluate.
        if (feedModel.get(i).sig !== sig) {
          feedModel.setProperty(i, "d", arr[i])
          feedModel.setProperty(i, "sig", sig)
        }
      } else {
        feedModel.append({ d: arr[i], sig: sig })
      }
    }
  }

  // --- Live feed for the selected session; mock when no daemon data yet ---
  // Debounced stream updates: rebuilding the whole feed model on every token
  // blocks the UI thread and stutters animations (the orb) + scrolling. Coalesce
  // rapid bumps into ~8 rebuilds/sec by depending on feedTick, not feedGen.
  property int feedTick: 0
  Timer {
    id: feedDebounce; interval: 120
    onTriggered: {
      rail.feedTick++
      rail.syncFeedModel()
      if (rail.view === "chat" && !rail.scrollGuarded
          && (rail.pinBottom || rail._wantBottom || rail._sendPin)) {
        if (rail._wantBottom || rail._sendPin) rail.cur = Math.max(0, rail.navTotal - 1)
        feedView.positionViewAtEnd()
        rail.pinBottom = true
        if (rail._wantBottom) bottomSettle.restart()   // FIRST load only — see _sendPin
        rail._wantBottom = false
        rail._sendPin = false
      }
    }
  }
  // On the first feed load the ListView's delegates aren't realized yet, so a
  // single positionViewAtEnd lands mid-feed (contentHeight is an estimate).
  // Re-pin a few times over ~500ms until the geometry settles at the true bottom.
  Timer {
    id: bottomSettle; interval: 60; repeat: true
    property int n: 0
    onTriggered: {
      if (rail.view === "chat" && rail.pinBottom && !rail.scrollGuarded) feedView.positionViewAtEnd()
      n++; if (n >= 9) { running = false; n = 0 }
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
  readonly property var groupedFeed: {
    var f = feed, out = [], cur = null
    for (var i = 0; i < f.length; i++) {
      var it = f[i]
      if (it.kind === "user") {
        if (cur) { out.push(cur); cur = null }
        out.push(it)
      } else {
        if (!cur) cur = { kind: "turn", items: [] }
        cur.items.push(it)
        if (it.kind === "text") { out.push(cur); cur = null }  // prose ends the card
      }
    }
    if (cur) out.push(cur)
    return out
  }

  ColumnLayout {
    anchors { top: parent.top; left: parent.left; right: parent.right; bottom: chin.top }
    anchors.margins: 20
    anchors.topMargin: 18     // just the inter-message gap above the roster card (no ROSTER header)
    anchors.bottomMargin: 0   // feed clips at chin.top (under the fade's full-opacity edge), no hard cut
    spacing: 18

    // Roster — all sessions in one discrete card. Rows are full-bleed within it;
    // the cursor row is an inverted ink pill, the selected session a faint tint.
    Rectangle {
      Layout.fillWidth: true
      clip: true
      implicitHeight: rail.rosterExpanded ? rosterInner.implicitHeight + 16
                                          : glanceCol.implicitHeight + 28   // extra room below the glance
      Behavior on implicitHeight { NumberAnimation { duration: 160; easing.type: Easing.InOutQuad } }
      // Item pills drive the container: container radius = item radius + padding.
      radius: 20 + 8   // (rowHeight/2) + padding → concentric with the pill rows
      color: Theme.surface0            // subtler than surface (barely-there tint)
      border.color: Theme.hairlineSoft; border.width: 1

      // Collapsed glance: active session name + a per-session status strip
      // (spinner while working, dot otherwise) + the toggle hint.
      Column {
        id: glanceCol
        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 16; rightMargin: 16; topMargin: 14 }
        spacing: 13
        opacity: rail.rosterExpanded ? 0 : 1
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 120 } }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: (rail.shortName(rail.selectedRaw) || "lovable").toUpperCase()
          color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: rail.fsName; font.bold: true
        }
        Row {
          anchors.horizontalCenter: parent.horizontalCenter   // centered strip
          spacing: 12
          Repeater {
            model: rail.rosterList
            Item {
              width: 12; height: 12
              Spinner {
                anchors.centerIn: parent; visible: modelData.status === "streaming"
                running: visible; color: Theme.green; dotSize: 2.0
              }
              Rectangle {
                anchors.centerIn: parent; visible: modelData.status !== "streaming"
                width: 7; height: 7; radius: 3.5; color: rail.dotColor(modelData.status)
              }
            }
          }
        }
      }

      ColumnLayout {
        id: rosterInner
        opacity: rail.rosterExpanded ? 1 : 0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 120 } }
        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 8; rightMargin: 8; topMargin: 8 }
        spacing: 3
        Repeater {
          model: rail.rosterList
          Rectangle {
            id: sessRow
            Layout.fillWidth: true
            implicitHeight: 40
            radius: height / 2   // pill rows (as before)
            // `!rail.insert` matters: the cursor fill means "keyboard is here", so
            // it must clear while the composer owns input (the feed + files
            // delegates already guard this way).
            readonly property bool cursor: rail.focused && !rail.insert && rail.cur === index
            readonly property bool selected: (modelData.rawName || modelData.name) === rail.selectedRaw
            readonly property bool streaming: modelData.status === "streaming"
            color: cursor ? Theme.fg
                 : selected ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.08)
                 : hov.hovered ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.04) : "transparent"
            HoverHandler { id: hov }
            // Collapsed: index doesn't map to the full list → just focus/expand.
            TapHandler { onTapped: rail.rosterExpanded ? rail.clickAt(index) : rail.requestFocus() }
            RowLayout {
              anchors { fill: parent; leftMargin: 12 + (modelData.depth || 0) * 20; rightMargin: 14 }
              spacing: 8
              // Nesting connector for spawned subagents.
              Text {
                visible: (modelData.depth || 0) > 0
                text: "↳"; color: sessRow.cursor ? Theme.bg : Theme.fg_muted
                font.family: Theme.fontFamily; font.pixelSize: rail.fsName
                Layout.alignment: Qt.AlignVCenter
              }
              Icon {
                name: "filters"; width: 14; height: 14
                Layout.preferredWidth: 14; Layout.preferredHeight: 14
                Layout.alignment: Qt.AlignVCenter
                color: sessRow.cursor ? Theme.bg : rail.dotColor(modelData.status)
              }
              // Where the agent actually runs: cloud = a lovbox worktree, laptop =
              // this machine. Muted on purpose — it's provenance, not status.
              Icon {
                // Filled 12px cuts, not the default outlines: at 13px the outline
                // laptop is indistinguishable from a plain rectangle — a house reads instantly.
                name: modelData.remote ? "cloud--glyph--12" : "house-2--glyph--12"
                width: 13; height: 13
                Layout.preferredWidth: 13; Layout.preferredHeight: 13
                Layout.alignment: Qt.AlignVCenter
                color: sessRow.cursor ? Theme.bg : Theme.fg_muted
                opacity: sessRow.cursor ? 0.8 : 0.65
              }
              Text {
                text: modelData.name; Layout.fillWidth: true; elide: Text.ElideRight
                color: sessRow.cursor ? Theme.bg : Theme.fg
                font.family: Theme.fontFamily; font.pixelSize: rail.fsName
                font.weight: (sessRow.selected || sessRow.streaming) ? 600 : 400
              }
              Text {
                text: modelData.state || modelData.idle || ""
                Layout.preferredWidth: 74; horizontalAlignment: Text.AlignRight
                Layout.alignment: Qt.AlignVCenter
                color: sessRow.cursor ? Theme.bg : sessRow.streaming ? Theme.electric : Theme.fg_muted
                font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
              }
              Icon {
                name: "plug-2"; width: 15; height: 15
                Layout.preferredWidth: 15; Layout.preferredHeight: 15   // equal dims → no squish
                Layout.alignment: Qt.AlignVCenter
                // Green = top-level session with its own worktree/devenv; muted =
                // a spawned subagent (shares the parent's, no devenv of its own).
                color: sessRow.cursor ? Theme.bg
                     : !modelData.linked ? Theme.green : Theme.fg_muted
                opacity: modelData.linked ? 0.5 : 1.0
              }
            }
          }
        }
      }
    }


    // Files view — full changed-files list for the selected session.
    ListView {
      id: changesView
      Layout.fillWidth: true
      Layout.fillHeight: rail.view === "files"
      visible: rail.view === "files"
      clip: true
      activeFocusOnTab: false
      model: rail.changesList
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
      Layout.fillHeight: rail.view === "chat"
      visible: rail.view === "chat"
      clip: true
      spacing: 18
      model: feedModel
      boundsBehavior: Flickable.StopAtBounds
      // NATIVE cursor-follow: ListView keeps currentIndex inside the preferred
      // range, scrolling as needed. This replaces ~120 lines of hand-rolled
      // contentY math (which mis-snapped via indexAt() returning -1 in the gaps).
      // The range IS the scroll margin: one spacing at the top, the composer's
      // footer pad at the bottom.
      currentIndex: (rail.view === "chat" && rail.cur >= rail.rSize) ? (rail.cur - rail.rSize) : -1
      highlightFollowsCurrentItem: true
      // ApplyRange re-evaluates the current item's position on EVERY model change, so
      // while a turn streams (rows updating ~8x/sec) it continuously yanked the view —
      // that was the "constant blinking", and it stopped the moment pinning kicked in
      // because that already disabled the range. Keep the range off for the whole
      // streaming window; cursor moves get one-shot positioning below instead.
      highlightRangeMode: rail.featuredStreaming ? ListView.NoHighlightRange : ListView.ApplyRange
      preferredHighlightBegin: spacing
      preferredHighlightEnd: height - 56
      highlightMoveDuration: 0
      highlightResizeDuration: 0
      highlight: null           // the delegate paints its own cursor fill
      // ScrollFeel is a WheelHandler that writes contentY DIRECTLY, so wheel
      // scrolling sets neither `dragging` nor `flicking` — its `scrolled` signal
      // is the only reliable "the user scrolled" event. Unpin when they leave the
      // bottom, re-arm follow when they return to it.
      // Scrolling UP always unpins; follow re-arms only when the user scrolls back
      // to within a hair of the true bottom. Do NOT trust atYEnd here — with async
      // delegates contentHeight is an estimate and atYEnd reports true mid-feed,
      // which left pinBottom armed and pinTimer yanking the viewport ("locked").
      ScrollFeel {
        flick: feedView
        onScrolled: (up) => {
          rail.noteUserScroll()
          if (up) rail.pinBottom = false
          else rail.pinBottom = (feedView.contentY >= feedView.contentHeight - feedView.height - 8)
        }
      }
      header: Item { width: feedView.width; height: feedView.spacing }   // top gap == inter-message gap, so the first card clears the chat-title hairline
      footer: Item { width: feedView.width; height: 56 }   // bottom scroll padding above the fade/pill
      // Hairline pinned to the feed's top edge (fixed overlay, not a scrolling
      // delegate) — marks where the chat clips, no layout-spacing hacks.
      Rectangle {
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: 1; color: Theme.hairline; z: 2
      }
      // Follow new content. Positioning synchronously on contentHeightChanged
      // re-triggers async delegate incubation → contentHeight changes → fires
      // again → a 100%-CPU refill loop under qs 0.3.0's render-loop incubation.
      // Instead: throttle-follow at ~30fps ONLY while streaming (bounded, can't
      // spin), and snap once when a message is added/removed (countChanged).
      Timer {
        id: pinTimer; interval: 250; repeat: true
        running: rail.followMode && !rail.scrollGuarded
        // Follow the bottom with the SUPPORTED api. Writing contentY directly (tried
        // 2026-08-12) fights ListView's own layout bookkeeping while the streaming
        // card resizes and the feed visibly blinks. A slower cadence also keeps the
        // resize-chase from reading as a bounce. Continuously following a resizing
        // list is inherently a little jumpy — the jitter-free fix is a BottomToTop
        // layout with a reversed model, which is a bigger refactor.
        onTriggered: feedView.positionViewAtEnd()
      }
      onCountChanged: if (rail.view === "chat" && rail.pinBottom && !rail.scrollGuarded) Qt.callLater(feedView.positionViewAtEnd)
      // Streaming content arrived as a hard pop. Fade added rows in — short enough
      // (140ms) that it never lags the bottom-follow, and `displaced` keeps the rows
      // below from jumping when one is inserted.
      add: Transition {
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 140; easing.type: Easing.OutQuad }
      }
      displaced: Transition {
        NumberAnimation { properties: "y"; duration: 140; easing.type: Easing.OutQuad }
      }
      // Manual scrolling wins over follow-the-stream. NOTE: do NOT use
      // onMovementStarted/Ended here — Flickable emits those for PROGRAMMATIC
      // contentY changes too, so pinTimer's positionViewAtEnd() (30x/sec) trips
      // them and oscillates pinBottom, wedging scrolling entirely. `dragging`
      // and `flicking` are user-gesture-only, so key off those.
      readonly property bool _atTrueBottom: contentY >= contentHeight - height - 8
      onDraggingChanged: rail.pinBottom = dragging ? false : feedView._atTrueBottom
      onFlickingChanged: if (!flicking) rail.pinBottom = feedView._atTrueBottom
      delegate: Item {
        id: turnDel
        width: feedView.width
        implicitHeight: card.implicitHeight
        property int rowIndex: index
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
          border.width: 1   // always outline the card (surface≈bg, so fill alone is invisible)
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
            }

            // User message body.
            Text {
              visible: turnDel.isUser
              width: cardCol.width
              text: turnDel.isUser ? rail.colorizeLinks(turnDel.turn.text) : ""
              color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
              linkColor: rail.summaryColor   // links match the summary hue (sky is too harsh); underline keeps them scannable
              wrapMode: Text.WordWrap; textFormat: Text.MarkdownText
              onLinkActivated: (u) => Quickshell.execDetached(["xdg-open", u])
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
              property string ekey: "turn-" + turnDel.rowIndex
              // The turn that is CURRENTLY working expands by default, so you can watch
              // which tools it's reaching for; finished turns stay condensed to the
              // one-line summary. An explicit tap always wins over the default.
              property bool liveTurn: turnDel.rowIndex >= rail.fSize - 1 && rail.featuredStreaming
              property bool expanded: (ekey in rail.expandedGroups)
                                      ? rail.expandedGroups[ekey] === true
                                      : liveTurn
            }
          }
        }
      }
    }

  }

  // ask_user card — mirrors the nvim rail's "needs your input" approval: a
  // bordered card pinned above the composer. confirm → y/n; select → 1–9;
  // input/editor → i to type. Answered via the rail's Keys / the composer.
  Rectangle {
    id: askCard
    readonly property var ask: rail.pendingAsk
    visible: ask !== null && rail.view === "chat"
    anchors { left: parent.left; right: parent.right; bottom: chin.top
              leftMargin: 20; rightMargin: 20; bottomMargin: 8 }
    implicitHeight: askCol.implicitHeight + 28
    height: implicitHeight
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
      }

      // input/editor → i to type
      Row {
        spacing: 8
        visible: askCard.ask && (askCard.ask.method === "input" || askCard.ask.method === "editor")
        KeyCap { text: "i"; anchors.verticalCenter: parent.verticalCenter }
        Text { text: "type a reply"; color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: rail.fsBody; anchors.verticalCenter: parent.verticalCenter }
      }

      Text {
        text: (askCard.ask && askCard.ask.method === "select") ? "press a number · esc cancels" : "esc cancels"
        color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
      }
    }
  }

  // Chin: an opaque bottom bar (composer + hints) anchored to the rail bottom,
  // like the sibling apps' statusbar. The feed is bounded to chin.top, so chat
  // rows can never bleed under the input/hints.
  Rectangle {
    id: chin
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
    height: 108   // fixed: composer + hints + padding, stable across the insert toggle
    color: Theme.bg

    ColumnLayout {
      id: chinCol
      anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 20; rightMargin: 20; topMargin: 14 }
      spacing: 10

      // Attachment chips — same shape as dsqrd/slqs/mlqs (paperclip + name + ✕), so
      // the family looks consistent. The name matches the inline reference exactly
      // (@.heidr-pastes/img1.png → "img1"), which is what makes "before: img1, after:
      // img2" unambiguous for the agent as well as for you.
      Flow {
        Layout.fillWidth: true
        spacing: 16
        visible: rail.pastedImages.length > 0
        Repeater {
          model: rail.pastedImages
          Rectangle {
            id: attachChip
            readonly property string imgName: String(modelData)
            readonly property bool referenced: rail.composerText.indexOf(imgName) >= 0
            // A real badge surface (dsqrd's chip is a bare row, but on the rail's chin
            // it needs a ground of its own to read as an attachment).
            implicitWidth: chipRow.implicitWidth + 18
            height: 24
            radius: 6
            color: Theme.surface0
            border.width: 1
            border.color: referenced ? Theme.electric : Theme.hairline
            Row {
            id: chipRow
            anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 8 }
            spacing: 6
            Icon {
              name: "paperclip"; width: 13; height: 13
              color: attachChip.referenced ? Theme.electric : Theme.fg_secondary
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              // "image 1", "image 2" … by position in THIS message (pastedImages clears
              // on send). The file keeps a unique name on disk so earlier messages'
              // attachments stay readable, but the label you see is per-message.
              text: "image " + (index + 1)
              color: attachChip.referenced ? Theme.fg : Theme.fg_muted
              font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
              font.pixelSize: rail.fsMeta
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "  ✕"; color: Theme.fg_muted
              font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
              TapHandler {
                onTapped: {
                  composerInput.text = composerInput.text.replace("@.heidr-pastes/" + attachChip.imgName + " ", "")
                  rail.pastedImages = rail.pastedImages.filter(function (m) { return m !== attachChip.imgName })
                }
              }
            }
            }
          }
        }
      }


      // Composer — real text input (i to enter, Esc/Ctrl+h to leave)
      Rectangle {
        Layout.fillWidth: true
        implicitHeight: 52   // extra vertical padding
        radius: height / 2   // fully rounded input
        color: Theme.surface0
        border.color: rail.insert ? Theme.electric : Theme.hairline
        border.width: 1
        RowLayout {
          anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
          spacing: 8
          Icon { name: "chevron-right"; width: 14; height: 14; color: Theme.electric }
          TextInput {
            id: composerInput
            Layout.fillWidth: true
            color: Theme.fg
            font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
            clip: true
            verticalAlignment: TextInput.AlignVCenter
            // Orange blinking caret, matching the sibling apps (Theme.cursor).
            cursorDelegate: Rectangle { width: 2; radius: 1; color: Theme.cursor; opacity: composerInput.cursorVisible ? 1 : 0 }
            onAccepted: {
              var pa = rail.pendingAsk
              if (pa && (pa.method === "input" || pa.method === "editor")) {
                if (text.trim().length) rail.answerAsk({ value: text })
              } else if (text.trim().length && rail.agentd) {
                rail.agentd.submit(rail.selectedRaw, text)
              }
              rail.pastedImages = []      // attachments belong to the message just sent
              rail.pinBottom = true
              rail._sendPin = true   // land on the new last row (no re-pin storm)
              // Stay in insert after sending — you almost always have a follow-up,
              // and dropping to normal mode meant pressing `i` again every time.
              // Esc / Ctrl+h still leave. (An answered ask_user is done, so exit.)
              text = ""
              if (pa && (pa.method === "input" || pa.method === "editor")) rail.exitInsert()
              else composerInput.forceActiveFocus()
            }
            Keys.onPressed: (e) => {
              var ctrl = (e.modifiers & Qt.ControlModifier)
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
                    : "message " + rail.featured.name + "…   (i to type, / for commands)"
              color: Theme.fg_muted; font: composerInput.font
            }
          }
        }
      }

      // Keybind hints (QsLib KeyCap/CapLabel), context-aware.
      RowLayout {
        Layout.fillWidth: true
        spacing: 6
        visible: !rail.insert
        Item { Layout.fillWidth: true }   // push hint chips to the right
        Repeater {
          model: [
            { k: "j/k", l: "move" },
            { k: "⇥",   l: rail.view === "files" ? "chat" : "files" },
            { k: "⏎",   l: rail.view === "files" ? "open" : "act" },
            { k: "y",   l: "copy" },
            { k: "f",   l: rail.hinting ? "pick" : "links" },
            { k: "i",   l: "type" },
            { k: "h",   l: "nvim" }
          ].concat(rail.featuredStreaming ? [{ k: "x", l: "stop" }] : [])
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

  // Fade the feed into the chin: a gradient from bg (bottom) to transparent (top)
  // sitting just above the chin, so messages dissolve behind the floating pill.
  Rectangle {
    id: feedFade
    // Soften the feed's bottom into the chin only when content actually runs
    // under it — at the bottom (atYEnd) the last message already clears the
    // chin, so the fade would just dim it for no reason.
    // Hidden at the end AND when the cursor is on the last message — the 56px
    // footer means atYEnd isn't reached even when the last card is fully shown.
    opacity: (rail.view === "chat" && !feedView.atYEnd && rail.cur < rail.navTotal - 1) ? 1 : 0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: 350; easing.type: Easing.InOutQuad } }
    anchors { left: parent.left; right: parent.right; bottom: chin.top; leftMargin: 3 }  // clear the focus accent
    height: 100
    z: 9   // below the left focus accent (z:10) so it never paints over it
    gradient: Gradient {
      GradientStop { position: 0.0; color: Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 0.0) }
      GradientStop { position: 1.0; color: Theme.bg }
    }
  }

  // Floating "thinking" pill — centered above the composer, overlaying the chat
  // (does NOT scroll with it). The feed's bottom spacer keeps messages clear of it.
  Rectangle {
    id: thinkPill
    opacity: (rail.view === "chat" && rail.featuredStreaming) ? 1 : 0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
    // Sits lower, closer to the composer. The fade gradient anchors to chin.top
    // separately, so this margin moves ONLY the pill.
    anchors { horizontalCenter: parent.horizontalCenter; bottom: chin.top; bottomMargin: 4 }
    implicitWidth: pillRow.implicitWidth + 22
    height: 40
    radius: height / 2
    color: Theme.surface0
    border.color: Theme.hairline; border.width: 1
    z: 20
    RowLayout {
      id: pillRow
      anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 8 }
      spacing: 9
      Orb { running: thinkPill.visible; glow: Theme.fg; Layout.preferredWidth: 26; Layout.preferredHeight: 26 }
      Text {
        text: "thinking…"; color: Theme.fg_secondary; rightPadding: 4
        font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
        SequentialAnimation on opacity {
          running: thinkPill.visible; loops: Animation.Infinite
          NumberAnimation { from: 0.5; to: 1.0; duration: 900; easing.type: Easing.InOutSine }
          NumberAnimation { from: 1.0; to: 0.5; duration: 900; easing.type: Easing.InOutSine }
        }
      }
    }
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
        model: expanded ? entry.cmds : []
        Text {
          x: 26
          text: modelData.text; color: Theme.fg_muted
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
        model: expanded ? items : []
        Loader {
          width: actCol.width
          property var entry: modelData
          property string gkey: ekey + "-" + index
          property bool expanded: rail.expandedGroups[gkey] === true
          sourceComponent: {
            var k = modelData.kind
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
    RowLayout {
      spacing: 8
      Icon { name: rail.toolIcon(entry.tool); width: 13; height: 13; color: Theme.fg_muted; Layout.alignment: Qt.AlignVCenter }
      Text {
        text: entry.text; color: Theme.fg_secondary
        font.family: Theme.fontFamily; font.pixelSize: rail.fsBody; elide: Text.ElideRight
        Layout.fillWidth: true
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
        text: rail.colorizeLinks(rail.hintify(proseCol._body, rowIndex)); color: Theme.fg
        linkColor: rail.summaryColor   // links match the summary hue; underline keeps them scannable
        font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
        wrapMode: Text.WordWrap; lineHeight: 1.35
        textFormat: Text.MarkdownText   // **bold**, `code`, lists — like the old rail
        onLinkActivated: (u) => Quickshell.execDetached(["xdg-open", u])
      }
      Text {
        visible: proseCol._summary.length > 0
        width: parent.width
        text: rail.colorizeLinks(proseCol._summary); color: rail.summaryColor
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

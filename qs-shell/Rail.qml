import QtQuick
import QtQuick.Layouts
import Quickshell
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
  property string activeRaw: ""
  // Roster collapses when the rail isn't focused (like the old nvim rail): it
  // shows just the active session's row; focusing it expands to the full list.
  // Ctrl+t overrides the auto behavior (sticky until toggled again or refocus).
  property var rosterOverride: null   // null = auto (follow focus); true/false = forced
  readonly property bool rosterExpanded: rosterOverride !== null ? rosterOverride : focused

  function copyText(s) { if (s && s.length) Quickshell.execDetached(["wl-copy", "--", String(s)]) }
  // On open, land nvim in the active session's worktree + its plan (if any),
  // replacing the default splash. Runs once (first session known).
  property bool _landed: false
  // Land a few times (500/1000/1500ms) so it catches whenever nvim's socket is
  // up — idempotent, and the intro is suppressed so nothing flashes meanwhile.
  Timer {
    id: landTimer; interval: 500; repeat: true
    property int n: 0
    onTriggered: { rail.landNvim(rail.selectedRaw); n++; if (n >= 3) { running = false; n = 0 } }
  }
  function landNvim(sid) {
    if (!sid || !agentd) return
    var cwd = ""
    for (var i = 0; i < agentd.sessions.length; i++)
      if (agentd.sessions[i].id === sid) { cwd = agentd.sessions[i].cwd; break }
    if (!cwd) return
    var m = String(sid).match(/every-(\d+)/i)
    var plan = m ? (Quickshell.env("HOME") + "/personal/notes/storage/plans/EVERY-" + m[1] + ".md") : ""
    // Open the plan if it exists; otherwise just cd into the worktree and leave
    // an empty buffer — never `edit` the dir (that opens netrw, which reads as
    // broken for a plan-less session like the orchestrator).
    var expr = plan
      ? ('execute(filereadable("' + plan + '") ? "cd ' + cwd + ' | edit ' + plan + '" : "cd ' + cwd + '")')
      : ('execute("cd ' + cwd + '")')
    var sock = Quickshell.env("XDG_RUNTIME_DIR") + "/heidr-nvim.sock"
    Quickshell.execDetached(["nvim", "--server", sock, "--remote-expr", expr])
  }

  function openInNvim(path) {
    if (!path || !String(path).length) return
    var p = String(path)
    // Resolve worktree-relative paths against the selected session's cwd — nvim's
    // own cwd is the cockpit dir, so a bare "web/…" would open an empty buffer.
    if (p.charAt(0) !== "/" && changesCwd) p = changesCwd + "/" + p
    var sock = Quickshell.env("XDG_RUNTIME_DIR") + "/heidr-nvim.sock"
    Quickshell.execDetached(["nvim", "--server", sock, "--remote", p])
    rail.focusNvim()
  }
  // Prose blocks of an agent turn (the headline answer).
  function turnProse(items) { return (items || []).filter(x => x.kind === "text") }
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
  onFocusedChanged: { rosterOverride = null; if (focused) { insert = false; forceActiveFocus() } }

  // Font scale anchored to the design system's base (Theme.fontSize = 14).
  readonly property int fsHeader: Theme.fontSize + 3
  readonly property int fsName:   Theme.fontSize + 2
  readonly property int fsBody:   Theme.fontSize + 1
  readonly property int fsMeta:   Theme.fontSize

  // HEIDR_DEMO=1 forces the mock showcase (working session + orb, every feed
  // kind, changed files) so all states are visible without a live session.
  readonly property bool demo: Quickshell.env("HEIDR_DEMO") === "1"

  // --- Roster: real agentd sessions when available, else mock ---
  readonly property var liveSessions:
    (agentd && agentd.sessions && agentd.sessions.length) ? agentd.sessions : []
  readonly property bool live: !demo && liveSessions.length > 0

  function shortName(n) {
    var s = String(n).replace(/^lovable\.daphen-/, "").replace(/^daphen-/, "")
    var m = s.match(/^([a-z]+-\d+)/)
    return m ? m[1] : s
  }
  function stateLabel(st) {
    if (st === "streaming") return "working"
    if (st === "asleep")    return "asleep"
    if (st === "error")     return "error"
    return "idle"
  }
  function dotColor(st) {
    if (st === "streaming") return Theme.green
    if (st === "error")     return Theme.red
    if (st === "asleep")    return Theme.fg_muted
    return Theme.electric
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
  readonly property string defaultRaw: {
    if (!live) return ""
    var roots = liveSessions.filter(s => !s.parent)
    var pool = (roots.length ? roots : liveSessions).slice()
    pool.sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
    return pool[0].name
  }
  readonly property string selectedRaw: activeRaw || defaultRaw

  readonly property var featured: {
    if (!live) return mockFeatured
    var arr = liveSessions.filter(s => s.name === selectedRaw)
    var f = arr.length ? arr[0] : liveSessions[0]
    return { name: shortName(f.name), rawName: f.name, state: stateLabel(f.status), status: f.status }
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
                 depth: Math.min(depth, 1) })  // one level deep only
      var kids = children[s.name] || []
      for (var j = 0; j < kids.length; j++) walk(kids[j], depth + 1)
    }
    for (var r = 0; r < roots.length; r++) walk(roots[r], 0)
    return out
  }
  property bool _wantBottom: false   // scroll chat to bottom once the new session's feed loads
  onSelectedRawChanged: {
    pinBottom = true
    _wantBottom = true
    if (agentd) agentd.select(selectedRaw)
    if (!_landed && selectedRaw) { _landed = true; landTimer.n = 0; landTimer.restart() }  // land nvim once, on open
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
  // j/k: if the focused card is taller than the viewport, scroll WITHIN it first;
  // only move to the next/prev card once it's fully scrolled into view.
  function moveDown() {
    if (cur < rSize) { cur = Math.min(cur + 1, rSize - 1); return }   // stay in roster
    if (view === "chat") {
      var it = feedView.itemAtIndex(cur - rSize)
      if (it && it.height > feedView.height - 8 && feedView.contentY + feedView.height < it.y + it.height - 4) {
        feedView.contentY = Math.min(it.y + it.height - feedView.height, feedView.contentY + feedView.height * 0.85)
        return
      }
    }
    cur = Math.min(cur + 1, navTotal - 1)
  }
  function moveUp() {
    if (cur < rSize) { cur = Math.max(cur - 1, 0); return }           // stay in roster
    if (view === "chat") {
      var it = feedView.itemAtIndex(cur - rSize)
      if (it && it.height > feedView.height - 8 && feedView.contentY > it.y + 4) {
        feedView.contentY = Math.max(it.y, feedView.contentY - feedView.height * 0.85)
        return
      }
    }
    cur = Math.max(cur - 1, rSize)   // stay in the chat/files view (Ctrl+k returns to roster)
  }

  Keys.onPressed: (e) => {
    if (insert) return
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
    else if (e.key === Qt.Key_O || e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { activateCur(); e.accepted = true }
  }
  // Keep the cursor visible as it moves into the main-area list.
  onCurChanged: {
    pinBottom = (cur >= navTotal - 1)   // at the last item → follow new messages
    if (cur < rSize) return
    if (view === "files") changesView.positionViewAtIndex(cur - rSize, ListView.Contain)
    else feedView.positionViewAtIndex(cur - rSize, ListView.Contain)
  }
  // subtle focus accent on the left edge (no full ring)
  Rectangle {
    width: 2; height: parent.height; anchors.left: parent.left
    color: Theme.electric; opacity: rail.focused ? 0.5 : 0; z: 10
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
      if (rail.view === "chat" && (rail.pinBottom || rail._wantBottom)) {
        rail.cur = Math.max(0, rail.navTotal - 1)
        feedView.positionViewAtEnd()
        rail.pinBottom = true
        rail._wantBottom = false
      }
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
    anchors.bottomMargin: 0   // feed clips at chin.top (under the fade's full-opacity edge), no hard cut
    spacing: 18

    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      Icon { name: "bolt"; width: rail.fsHeader; height: rail.fsHeader; color: Theme.orange }
      Text {
        text: "ROSTER"
        color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: rail.fsHeader; font.bold: true
      }
      Text {
        text: "· lovable"
        color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: rail.fsHeader
      }
      Item { Layout.fillWidth: true }
    }

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
            readonly property bool cursor: rail.focused && rail.cur === index
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
                name: "nodes"; width: 14; height: 14
                Layout.preferredWidth: 14; Layout.preferredHeight: 14
                Layout.alignment: Qt.AlignVCenter
                color: sessRow.cursor ? Theme.bg : rail.dotColor(modelData.status)
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

    // View header: which main area is showing (Tab toggles chat ↔ files).
    RowLayout {
      Layout.fillWidth: true
      spacing: 6
      Icon { name: rail.view === "files" ? "nodes" : "msgs"; width: rail.fsMeta; height: rail.fsMeta; color: Theme.fg_muted }
      Text {
        text: rail.view === "files" ? ("FILES · " + rail.cSize) : "CHAT"
        color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta; font.bold: true
      }
      Item { Layout.fillWidth: true }
      Text {
        text: "⇥ " + (rail.view === "files" ? "chat" : "files")
        color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta
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
        readonly property bool cursor: rail.focused && rail.cur === rail.rSize + index
        color: cursor ? Qt.rgba(Theme.selection.r, Theme.selection.g, Theme.selection.b, 0.6)
             : chov.hovered ? Qt.rgba(Theme.selection.r, Theme.selection.g, Theme.selection.b, 0.4) : "transparent"
        border.width: cursor ? 1 : 0
        border.color: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.35)
        HoverHandler { id: chov }
        TapHandler { onTapped: rail.clickAt(rail.rSize + index) }
        RowLayout {
          anchors { fill: parent; leftMargin: 6; rightMargin: 6 }
          spacing: 8
          Icon { name: "pen-3"; width: 12; height: 12; color: Theme.fg_muted; Layout.alignment: Qt.AlignVCenter }
          Text { text: modelData.path; color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta; elide: Text.ElideMiddle; Layout.fillWidth: true }
          Text { text: "+" + modelData.add; color: Theme.green; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta }
          Text { text: "-" + modelData.del; color: Theme.red; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta }
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
      model: rail.groupedFeed
      boundsBehavior: Flickable.StopAtBounds
      ScrollFeel { flick: feedView }
      footer: Item { width: feedView.width; height: 56 }   // bottom scroll padding above the fade/pill
      // Hairline pinned to the feed's top edge (fixed overlay, not a scrolling
      // delegate) — marks where the chat clips, no layout-spacing hacks.
      Rectangle {
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: 1; color: Theme.hairline; z: 2
      }
      // Follow new content while streaming (message grows without a count change).
      onContentHeightChanged: if (rail.view === "chat" && rail.pinBottom) positionViewAtEnd()
      delegate: Item {
        id: turnDel
        width: feedView.width
        implicitHeight: card.implicitHeight
        property int rowIndex: index
        readonly property bool isUser: modelData.kind === "user"
        readonly property bool cursor: rail.focused && rail.cur === rail.rSize + rowIndex

        Rectangle {
          id: card
          anchors { left: parent.left; right: parent.right }
          implicitHeight: cardCol.implicitHeight + 36
          radius: 14
          color: turnDel.isUser ? Theme.surface0 : Theme.surface
          border.width: 1   // always outline the card (surface≈bg, so fill alone is invisible)
          border.color: turnDel.cursor ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.30) : Theme.hairline
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
                name: turnDel.isUser ? "user" : "sparkle-3"
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
              text: turnDel.isUser ? modelData.text : ""
              color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
              wrapMode: Text.WordWrap; textFormat: Text.MarkdownText
            }

            // Thought process — visible inline. Each block shows its short header;
            // tap to reveal the full reasoning.
            Repeater {
              model: turnDel.isUser ? [] : rail.turnThinks(modelData.items)
              Loader {
                width: cardCol.width
                sourceComponent: thinkRow
                property var entry: modelData
                property string gkey: "think-" + turnDel.rowIndex + "-" + index
                property bool expanded: rail.expandedGroups[gkey] === true
              }
            }

            // Agent prose — the headline answer (each text block).
            Repeater {
              model: turnDel.isUser ? [] : rail.turnProse(modelData.items)
              Loader {
                width: cardCol.width
                property var entry: modelData
                sourceComponent: proseRow
              }
            }

            // Compact activity summary — "4 bash · 6 read · edited 3", expandable.
            Loader {
              active: !turnDel.isUser && rail.turnActivitySummary(modelData.items).length > 0
              visible: active
              width: cardCol.width
              sourceComponent: activityRow
              property var items: turnDel.isUser ? [] : rail.turnActivityItems(modelData.items)
              property string summary: active ? rail.turnActivitySummary(modelData.items) : ""
              property string ekey: "turn-" + turnDel.rowIndex
              property bool expanded: rail.expandedGroups[ekey] === true
            }
          }
        }
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
            onAccepted: {
              if (text.trim().length && rail.agentd) rail.agentd.sendPrompt(rail.selectedRaw, text)
              text = ""; rail.exitInsert()
            }
            Keys.onPressed: (e) => {
              var ctrl = (e.modifiers & Qt.ControlModifier)
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
              text: "message " + rail.featured.name + "…   (i to type, / for commands)"
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
            { k: "i",   l: "type" },
            { k: "h",   l: "nvim" }
          ]
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

  // Fade the feed into the chin: a gradient from bg (bottom) to transparent (top)
  // sitting just above the chin, so messages dissolve behind the floating pill.
  Rectangle {
    id: feedFade
    // Always soften the feed's bottom into the chin (no sharp cutoff).
    opacity: rail.view === "chat" ? 1 : 0
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
    opacity: (rail.view === "chat" && rail.featured.status === "streaming") ? 1 : 0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
    anchors { horizontalCenter: parent.horizontalCenter; bottom: chin.top; bottomMargin: 14 }
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
      Icon { name: "sparkle-3"; width: 13; height: 13; color: Theme.fg_muted; Layout.alignment: Qt.AlignTop; Layout.topMargin: 3 }
      Text {
        text: (typeof expanded !== "undefined" && expanded && entry.full) ? entry.full : entry.text
        color: Theme.fg_muted
        font.family: Theme.fontFamily; font.pixelSize: rail.fsBody; font.italic: true
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
    // the surface. No inner box/accent (that double-boxing looked heavy).
    Text {
      text: entry.text; color: Theme.fg
      font.family: Theme.fontFamily; font.pixelSize: rail.fsBody
      wrapMode: Text.WordWrap
      lineHeight: 1.35   // airier prose
      textFormat: Text.MarkdownText   // **bold**, `code`, lists — like the old rail
      onLinkActivated: (u) => Quickshell.execDetached(["xdg-open", u])
    }
  }
  Component {
    id: editRow
    RowLayout {
      spacing: 8
      Icon { name: "pen-3"; width: 13; height: 13; color: Theme.fg_muted; Layout.alignment: Qt.AlignVCenter }
      Text { text: entry.file; color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: rail.fsBody; font.bold: true; elide: Text.ElideMiddle; Layout.fillWidth: true }
      // Diff stats only when known (live edits); transcript edits carry none.
      Text { visible: (entry.add + entry.del) > 0; text: "+" + entry.add; color: Theme.green; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta }
      Text { visible: (entry.add + entry.del) > 0; text: "-" + entry.del; color: Theme.red; font.family: Theme.fontFamily; font.pixelSize: rail.fsMeta }
    }
  }
}

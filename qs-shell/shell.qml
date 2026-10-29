import QtQuick
import Quickshell
import Quickshell.Io
import QsLib
import Heidr

// Cockpit: nvim (librio terminal) left, the agent rail right.
// Super+h/l focus moves nvim <-> rail via the IpcHandler below (niri calls it,
// falling back to window-focus at the edges — the "smart-splits" bridge).
ShellRoot {
  FloatingWindow {
    id: win
    readonly property color ground: Theme.mode === "dark" ? Qt.tint(Theme.bgDim, Qt.alpha(Theme.fg, 0.03)) : Qt.darker(Theme.bgDim, 1.04)
    readonly property string instanceName: Quickshell.env("COCKPIT_INSTANCE") || "main"
    readonly property string startupMode: {
      var s = Quickshell.env("COCKPIT_SCOPE") || Quickshell.env("HEIDR_SCOPE") || "personal"
      return s === "lovable" || s === "work" ? "work" : "personal"
    }
    readonly property string modeStatePath: Quickshell.env("HOME") + "/.local/state/cockpit/mode-" + instanceName
    property string scopeMode: startupMode
    property string remoteEditorSocket: ""
    property string editorSocket: ""
    onScopeModeChanged: if (scopeMode === "personal") editorSocket = ""
    Process {
      running: true
      command: ["vmctl", "editor", win.instanceName, Quickshell.instanceId]
      stdout: SplitParser {
        onRead: data => {
          var socket = data.trim()
          if (!socket) return
          if (socket === win.remoteEditorSocket) remoteFocus.refresh()
          win.remoteEditorSocket = socket
          if (win.scopeMode === "work") Qt.callLater(() => rail.landNvim(rail.selectedRaw))
        }
      }
    }
    property bool modeReady: false
    readonly property var agentd: scopeMode === "work" ? workAgentd : personalAgentd
    FileView {
      id: ticketCache
      path: Quickshell.env("HOME") + "/.local/state/lovable/cycle.json"
      watchChanges: true
      printErrors: false
      onFileChanged: reload()
      adapter: JsonAdapter {
        property var tickets: []
        property var session_tickets: []
      }
    }
    TicketStatuses {
      id: ticketStatuses
      sessions: dashboard.workers
      enabled: win.dashboardActive && dashboard.showSessions
    }
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR")
    function envSockPaths() {
      var raw = String(Quickshell.env("COCKPIT_AGENTD_SOCKS") || Quickshell.env("HEIDR_AGENTD_SOCKS") || "").trim()
      return raw ? raw.split(",").map(p => p.trim()).filter(p => p.length > 0) : null
    }
    function pathsFor(mode) {
      var custom = envSockPaths()
      if (custom) {
        var personal = p => /-personal\.sock$/.test(p)
        var work = p => /-(work|lovable)\.sock$/.test(p)
        // Keep custom sockets, but never place a known other-scope socket in this roster.
        if (mode === startupMode) return custom.filter(p => !(mode === "work" ? personal(p) : work(p)))
        var matching = custom.filter(mode === "work" ? work : personal)
        if (matching.length) return matching
      }
      return mode === "work"
        ? [runtimeDir + "/agentd-lovable.sock", runtimeDir + "/agentd-work.sock"]
        : [runtimeDir + "/agentd-personal.sock"]
    }
    function setScopeMode(mode) {
      var next = mode === "work" ? "work" : "personal"
      if (next === scopeMode) return
      personalAgentd.setPresence("")
      workAgentd.setPresence("")
      scopeMode = next
      modeWrite.running = false
      modeWrite.command = ["sh", "-c", 'mkdir -p "$1"; printf %s "$2" > "$3"',
                           "sh", Quickshell.env("HOME") + "/.local/state/cockpit", next, modeStatePath]
      modeWrite.running = true
      Qt.callLater(syncPresence)
    }
    function restoreScopeMode(mode) {
      var next = mode === "work" ? "work" : mode === "personal" ? "personal" : ""
      if (!next || next === scopeMode) return
      personalAgentd.setPresence("")
      workAgentd.setPresence("")
      scopeMode = next
      Qt.callLater(syncPresence)
    }
    FileView {
      id: modeState
      path: win.modeStatePath
      watchChanges: true
      onFileChanged: reload()
      onLoaded: {
        win.restoreScopeMode(String(text() || "").trim())
        win.modeReady = true
        win.syncPresence()
      }
      onLoadFailed: {
        win.modeReady = true
        win.syncPresence()
      }
    }
    title: "cockpit-qs · " + scopeMode + " · " + instanceName
    visible: true       // match mlqs — a cold-started FloatingWindow must map explicitly
    // Wide by default: the cockpit is two panes (nvim ~60% + rail ~40%), so 1600
    // left the terminal too narrow for real code once the rail took its share.
    implicitWidth: 2400
    implicitHeight: 1300
    minimumSize: Qt.size(640, 400)   // let niri's set-column-width actually shrink it
    onClosed: Qt.quit()              // niri close-window quits (FloatingWindow ignores it otherwise)

    property string pane: "nvim"   // "nvim" | "rail"
    property bool railCollapsed: false
    property bool railLayoutCollapsed: false
    property real railReveal: 1
    readonly property bool dashboardActive: !!(chin.st.dashboard && chin.st.dashboard.active)

    Behavior on railReveal {
      NumberAnimation {
        duration: Motion.med
        easing.type: Motion.easeEmphasized
        easing.bezierCurve: Motion.curveDecel
      }
    }
    Timer {
      id: railLayoutTimer
      interval: Motion.med
      onTriggered: if (!win.railCollapsed) win.railLayoutCollapsed = false
    }
    function toggleRail() {
      if (railCollapsed) {
        railCollapsed = false
        railReveal = 0
        railLayoutTimer.restart()
        Qt.callLater(function() { railReveal = 1 })
        return
      }
      railCollapsed = true
      railLayoutTimer.stop()
      railLayoutCollapsed = true
      pane = "nvim"
      railReveal = 0
      Qt.callLater(function() {
        if (dashboardActive) dashboard.forceActiveFocus()
        else term.forceActiveFocus()
      })
    }
    Shortcut {
      sequence: "Ctrl+Shift+F"
      context: Qt.ApplicationShortcut
      onActivated: win.toggleRail()
    }

    Shortcut {
      sequence: "Ctrl+Tab"
      context: Qt.ApplicationShortcut
      onActivated: rail.showWorkspace("cycle")
    }
    Shortcut {
      sequence: "Ctrl+Shift+H"
      context: Qt.ApplicationShortcut
      onActivated: viewTabs.cycle(-1)
    }
    Shortcut {
      sequence: "Ctrl+Shift+L"
      context: Qt.ApplicationShortcut
      onActivated: viewTabs.cycle(1)
    }
    Shortcut {
      sequence: "Ctrl+1"
      context: Qt.ApplicationShortcut
      onActivated: rail.showWorkspace("diff")
    }
    Shortcut {
      sequence: "Ctrl+2"
      context: Qt.ApplicationShortcut
      onActivated: rail.showWorkspace("plan")
    }
    Shortcut {
      sequence: "Ctrl+3"
      context: Qt.ApplicationShortcut
      onActivated: rail.showWorkspace("dashboard")
    }
    Shortcut {
      sequence: "Ctrl+F"
      context: Qt.ApplicationShortcut
      enabled: win.dashboardActive && win.pane === "nvim"
      onActivated: rail.showWorkspace("diff")
    }

    FocusCache { nvimSocket: term.localNvimSocket }
    FocusCache { id: remoteFocus; nvimSocket: win.remoteEditorSocket }

    readonly property bool windowFocused: term.activeFocus || dashboard.activeFocus || rail.activeFocus
    NotificationFocus {
      active: win.modeReady && win.windowFocused && !win.railCollapsed
      session: rail.selectedRaw
    }
    function syncPresence() {
      personalAgentd.setPresence(modeReady && scopeMode === "personal" && windowFocused ? rail.selectedRaw : "")
      workAgentd.setPresence(modeReady && scopeMode === "work" && windowFocused ? rail.selectedRaw : "")
    }
    onWindowFocusedChanged: syncPresence()
    Component.onCompleted: syncPresence()
    Connections {
      target: rail
      function onSelectedRawChanged() { win.syncPresence() }
    }

    // Returns "consumed" if it moved internal focus, "passed" if already at the
    // edge (the niri script then does its normal window focus).
    function tryFocus(dir) {
      // Heal a pane/focus desync first: a QML hot-reload rebuilds the window tree and
      // can leave `pane` claiming the rail while the keyboard truly sits in the
      // terminal — the cross then answers "passed" and Ctrl+l goes dead. Reality wins.
      if ((term.activeFocus || dashboard.activeFocus) && win.pane !== "nvim") win.pane = "nvim"
      else if (rail.activeFocus && win.pane !== "rail") win.pane = "rail"
      if (dir === "right") {
        if (win.railCollapsed) return "passed"
        if (win.pane === "nvim") { win.pane = "rail"; return "consumed" }
        return "passed"
      } else {
        if (win.pane === "rail") { win.pane = "nvim"; return "consumed" }
        return "passed"
      }
    }

    onPaneChanged: {
      if (win.pane === "nvim") {
        if (win.dashboardActive) dashboard.forceActiveFocus()
        else term.forceActiveFocus()
      } else rail.forceActiveFocus()
    }
    onDashboardActiveChanged: {
      if (win.pane === "nvim") Qt.callLater(function() {
        if (win.dashboardActive) dashboard.forceActiveFocus()
        else term.forceActiveFocus()
      })
    }

    IpcHandler {
      target: "cockpit"
      function focusLeft(): string  { return win.tryFocus("left") }
      function focusRight(): string { return win.tryFocus("right") }
      function pane(): string {
        // Report reality, not the cached property: hot-reloads leave win.pane stale
        // ("rail" while the keyboard truly sits in the terminal), and Super+T's
        // "already on the rail?" check then hopped cockpits straight from the terminal.
        if ((term.activeFocus || dashboard.activeFocus) && win.pane !== "nvim") win.pane = "nvim"
        return win.pane
      }
      function title(): string      { return win.title }   // cockpit-ipc instance routing
      function scopeMode(): string  { return win.scopeMode }
      function switchScope(): string { win.setScopeMode(win.scopeMode === "work" ? "personal" : "work"); return win.scopeMode }
      // Parent binding for the pane's nvim: its NVIM_LISTEN_ADDRESS is unique to THIS
      // instance, so cockpit-cross can target its own Cockpit without asking niri anything.
      function nvimSock(): string   { return term.nvimSocket }
      function clipboardText(kind: string): string { return term.clipboardText(kind) }
      function attachAgentd(path: string): string { return workAgentd.attachSocket(path) ? "ok" : "rejected" }
      function focusRoster(): string { win.pane = "rail"; rail.focusRoster(); return "ok" }
      // Super+i ask-jump: land on the session that needs an answer.
      function selectSession(n: string): string { win.pane = "rail"; rail.jumpToSession(n); return "ok" }
      // `i` on the nvim dashboard: jump straight into the rail composer instead of
      // erroring on the read-only buffer. callLater lets the pane switch settle first.
      function focusComposer(): string { win.pane = "rail"; Qt.callLater(rail.enterInsert); return "ok" }
      function editorContext(path: string): string { return rail.receiveEditorContext(path) }
      // Super+T's whole in-window decision as ONE call (it was pane + railState +
      // focusRoster — three qs spawns): land on this window's roster unless the cursor
      // is genuinely parked there in normal mode, in which case report "parked" so the
      // script can hop cockpits.
      function rosterHop(): string {
        const onRoster = win.pane === "rail" && !term.activeFocus
                       && !rail.insert && rail.cur < rail.rSize
        if (onRoster) return "parked"
        win.pane = "rail"
        rail.focusRoster()
        return "landed"
      }
      // Super+T semantics = the in-app Ctrl+T: open the roster and park; pressed
      // again while parked, put it away. STRICTLY this window — no cockpit hop.
      function rosterToggle(): string {
        const onRoster = win.pane === "rail" && !term.activeFocus
                       && !rail.insert && rail.cur < rail.rSize
        if (rail.rosterExpanded && onRoster) {
          rail.rosterOverride = false
          Qt.callLater(rail.enterInsert)
          return "collapsed"
        }
        win.pane = "rail"
        rail.focusRoster()
        return "landed"
      }
      // The rail's test interface (test/rail-nav.sh): cursor/scroll behaviour depends on
      // the roster and feed changing UNDER the cursor, which is only assertable from
      // outside the process.
      function railState(): string {
        return JSON.stringify({ cur: rail.cur, rSize: rail.rSize, navTotal: rail.navTotal,
                                view: rail.view, mode: rail.scrollMode,
                                sel: rail.selectedRaw, scopeMode: win.scopeMode, key: rail.cursorKey,
                                ins: rail.insert, ask: !!rail.pendingAsk, askDeferred: rail.askDeferred, stale: !!rail.staleAsk,
                                q: rail.agentd ? rail.agentd.queuedFor(rail.selectedRaw) : 0,
                                hint: rail.hinting, yank: rail.yankMode, labels: rail.hintLabels.length,
                                asksTotal: rail.agentd ? (rail.agentd.askGen >= 0 ? rail.agentd.askCount() : 0) : 0,
                                keys: rail.keyLog, lastCancel: rail.lastCancel,
                                pCards: rail.probeCardCreates, pDots: rail.probeDotCreates, pResets: rail.probeFullResets, pActs: rail.probeActCreates, im: rail.imode,
                                row: rail.curRowText() })
      }
      function railKey(k: string): string { rail.debugNav(k); return "ok" }
      // Rendered prose of the focused feed row — what the user actually SEES,
      // after the badge/hint/colorize pipeline (test probe).
      function railProse(): string { return rail.probeProse() }
      function termGeom(): string { return term.gridInfo }
      function dashboardState(): string {
        return JSON.stringify({ active: win.dashboardActive, kind: String(dashboard.model.kind || ""),
                                termMounted: !!term, dashboardMounted: !!dashboard,
                                termEnabled: term.enabled, dashboardEnabled: dashboard.enabled,
                                termOpacity: term.opacity, dashboardOpacity: dashboard.opacity,
                                pane: win.pane, tab: viewTabs.current, tabs: viewTabs.views })
      }
      // Last N feed rows of the selected session, raw (test probe).
      function railTail(): string {
        var f = rail.agentd ? (rail.agentd.feeds[rail.selectedRaw] || []) : []
        return JSON.stringify(f.slice(-16).map(x => (x.tool || x.kind) + ":" + String(x.text || "").slice(0, 40)))
      }
      // Test-only sends, so the harness can drive the steer/queue/abort model.
      function railSend(t: string): string { if (rail.agentd) rail.agentd.submit(rail.selectedRaw, t); return "ok" }
      function railQueue(t: string): string { if (rail.agentd) rail.agentd.enqueue(rail.selectedRaw, t); return "ok" }
      // Realized feed rows as y/height/implicitHeight/cardHeight — the only way to see
      // whether chat cards are drawn on top of each other.
      function railGeom(): string { return JSON.stringify(rail.feedGeom()) }
      // How far the viewport sits from the live edge, in px. 0 = pinned to the bottom.
      // "It doesn't scroll down when messages arrive" is exactly this number, and nothing
      // else reports it: mode says "follow" while the view sits a card and a half behind.
      function railScroll(): string { return JSON.stringify(rail.feedScrollState()) }
      // Merged roster as "scope/name status" lines — proves which daemon owns what
      // when several sockets are wired up (COCKPIT_AGENTD_SOCKS).
      function sessions(): string {
        var out = []
        for (var i = 0; i < win.agentd.sessions.length; i++) {
          var s = win.agentd.sessions[i]
          out.push((s.scope || "?") + "/" + s.name + " " + (s.status || "?"))
        }
        return out.length ? out.join("\n") : "(empty)"
      }
    }

    // Mirrored off the terminal so its own width/height bindings never reference a
    // property of the item they are sizing — that self-reference resolved late and left
    // the width unsnapped while the height snapped correctly.
    readonly property real termDpr: term.dpr > 0 ? term.dpr : 1

    Process { id: modeWrite }
    AgentdState {
      id: personalAgentd
      scope: "personal"
      selectedSession: win.modeReady && win.scopeMode === "personal" ? rail.selectedRaw : ""
      configuredSockPaths: win.pathsFor("personal")
    }
    AgentdState {
      id: workAgentd
      scope: "lovable"
      selectedSession: win.modeReady && win.scopeMode === "work" ? rail.selectedRaw : ""
      configuredSockPaths: win.pathsFor("work")
    }

    Rectangle {
      anchors.fill: parent
      // bgDim, not bg: the term column's dpr-snapped width is fractional, so a
      // sub-pixel seam of this root can peek out at the term/rail boundary —
      // in bg (white on light) that read as a stray white line. Every child
      // paints its own ground, so the root only ever shows in seams.
      color: win.ground

      Item {
        id: paneLayout
        anchors.fill: parent
        readonly property real splitX: Math.round(width * 0.6 * win.termDpr) / win.termDpr
        readonly property real terminalCornerRadius: 8

        Column {
          id: termCol
          width: win.railLayoutCollapsed ? parent.width : paneLayout.splitX
          height: parent.height
          Item {
            id: viewTabs
            objectName: "workspaceViewTabs"
            z: 1
            width: parent.width
            height: 46
            readonly property string reported: win.dashboardActive ? "dashboard"
              : chin.st.view === "plan" && rail.selectedPlan ? "plan"
              : /\/notes\/storage$/.test(String(chin.st.cwd || "")) ? "vault" : "code"
            readonly property string current: rail.workspaceTab === "plan" && !rail.selectedPlan ? "code" : rail.workspaceTab
            readonly property var tabs: [{ view: "code", label: "Code", icon: "file-content" }, { view: "dashboard", label: "Dashboard", icon: "gauge-3" }, { view: "vault", label: "Vault", icon: "vault-3" }]
              .concat(rail.selectedPlan ? [{ view: "plan", label: "Plan", icon: "clipboard-check" }] : [])
            readonly property var views: tabs.map(function(tab) { return tab.view })
            function cycle(step) { rail.showWorkspace(views[(views.indexOf(current) + step + views.length) % views.length]) }
            Rectangle {
              id: viewBar
              readonly property int padding: 4
              readonly property bool lightMode: Theme.mode === "light"
              anchors.fill: parent
              color: win.ground
            }
            Row {
              id: viewRow
              anchors { fill: parent; margins: 7; rightMargin: 0 }
              spacing: 6
              Repeater {
                id: viewTabRepeater
                model: viewTabs.tabs
                delegate: Item {
                  id: viewTab
                  required property var modelData
                  objectName: "workspaceViewTab"
                  readonly property string view: modelData.view
                  width: (viewRow.width - (viewTabs.tabs.length - 1) * viewRow.spacing) / viewTabs.tabs.length
                  height: parent.height
                  readonly property bool active: viewTabs.current === view
                  readonly property bool focusMark: active && (term.activeFocus || dashboard.activeFocus)
                  readonly property color ink: active || viewTabHover.hovered ? rail.palette.fg : rail.palette.muted
                  LightKey {
                    anchors.fill: parent
                    visible: viewBar.lightMode
                    radius: paneLayout.terminalCornerRadius
                    outline: Qt.alpha(rail.palette.fg, viewTab.active ? 0.16 : 0.11)
                    faceTop: viewTab.active ? "#FDFDFD" : viewTabHover.hovered ? "#FBFBFB" : "#F9F9F9"
                    faceBottom: viewTab.active ? "#F5F5F6" : viewTabHover.hovered ? "#F3F3F4" : "#EFEFF0"
                  }
                  GradientFrame {
                    id: viewPill
                    anchors.fill: parent
                    visible: !viewBar.lightMode
                    radius: paneLayout.terminalCornerRadius
                    fill: Qt.tint(win.ground, viewTab.active ? rail.palette.itemSelected
                         : viewTabHover.hovered ? rail.palette.itemHover
                         : Qt.alpha(rail.palette.fg, 0.06))
                    edge: rail.palette.fg
                    strength: viewTab.active || viewTabHover.hovered ? 1 : 0.85
                    lowEdge: viewTab.active ? 0.2 : 0.05
                    fillTop: viewTab.active ? fill : Qt.tint(fill, Qt.alpha(rail.palette.fg, 0.035))
                    Behavior on fill { ColorAnimation { duration: 140 } }
                  }
                  Row {
                    anchors { left: parent.left; leftMargin: 5; right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                    spacing: 9
                    GradientFrame {
                      id: viewBadge
                      anchors.verticalCenter: parent.verticalCenter
                      width: 22; height: 22; radius: paneLayout.terminalCornerRadius - 3
                      fill: viewBar.lightMode ? Qt.tint("#FAFAFA", Qt.alpha(rail.palette.fg, viewTab.active ? 0.04 : 0.03))
                        : Qt.tint(viewPill.fill, Qt.alpha(rail.palette.fg, viewTab.active ? 0.07 : 0.04))
                      edge: viewPill.edge
                      strength: viewPill.strength * (viewBar.lightMode ? 0.6 : 1.2)
                      lowEdge: viewTab.active || viewBar.lightMode ? 0.2 : 0.05
                      fillTop: viewTab.active || viewBar.lightMode ? fill : Qt.tint(fill, Qt.alpha(rail.palette.fg, 0.04))
                      Icon {
                        anchors.centerIn: parent
                        name: viewTab.modelData.icon; width: 13; height: 13
                        color: viewTab.focusMark ? Theme.orange : viewTab.ink
                        Behavior on color { ColorAnimation { duration: 140 } }
                      }
                    }
                    Item {
                      anchors.verticalCenter: parent.verticalCenter
                      width: parent.width - viewBadge.width - parent.spacing
                      height: viewLabel.implicitHeight
                      clip: true
                      Text {
                        id: viewLabel
                        anchors.verticalCenter: parent.verticalCenter
                        text: viewTab.modelData.label
                        color: viewTab.ink
                        font.family: rail.messageFontFamily; font.pixelSize: rail.fsMeta
                        font.weight: viewTab.active ? 600 : 400
                      }
                      Rectangle {
                        visible: viewLabel.implicitWidth > parent.width
                        anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
                        width: Math.min(28, parent.width)
                        gradient: Gradient {
                          orientation: Gradient.Horizontal
                          GradientStop { position: 0; color: Qt.alpha(viewPill.fill, 0) }
                          GradientStop { position: 1; color: viewPill.fill }
                        }
                      }
                    }
                  }
                  HoverHandler { id: viewTabHover; cursorShape: Qt.PointingHandCursor }
                  TapHandler { onTapped: rail.showWorkspace(viewTab.view) }
                }
              }
            }
          }
          Item {
            id: renderStack
            width: parent.width
            height: Math.round((parent.height - viewTabs.height - chin.implicitHeight) * win.termDpr) / win.termDpr

            Crossfade {
              anchors.fill: parent
              // Follow the picked tab, not the editor's report, so its text never shows first.
              showSecond: rail.workspaceTab === "dashboard"
              enterDuration: 100
              exitDuration: 100
              shift: 0
              blurAmount: 0
              first: TermView {
                id: term
                nvimSocket: win.editorSocket
                anchors.fill: parent
                active: activeFocus && !glideCaret.holding
                enabled: !win.dashboardActive
                Component.onCompleted: forceActiveFocus()
                onActiveFocusChanged: if (activeFocus) win.pane = "nvim"
                SequentialAnimation {
                  id: termSwitchFade
                  OpacityAnimator { target: term; to: 0; duration: Motion.base; easing.type: Easing.OutCubic }
                  OpacityAnimator { target: term; to: 1; duration: 220; easing.type: Easing.OutCubic }
                }
                Connections {
                  target: rail
                  function onSelectedRawChanged() { termSwitchFade.restart() }
                }
              }
              second: Dashboard {
                id: dashboard
                anchors.fill: parent
                // Leaving for another editor resets chin.st; keep the cards through the fade-out.
                Binding on model {
                  when: win.dashboardActive
                  value: (chin.st.dashboard && chin.st.dashboard.model) || ({})
                  restoreMode: Binding.RestoreNone
                }
                sessions: win.agentd.sessions
                focusedSession: rail.selectedRaw
                tickets: ticketCache.adapter.tickets.concat(ticketCache.adapter.session_tickets)
                ticketStates: ticketStatuses.states
                askFor: sid => { win.agentd.askGen; return win.agentd.askFor(sid) }
                answerSendingFor: sid => !!win.agentd._answerIntents[sid]
                onAnswerRequested: (sid, payload) => win.agentd.answerAsk(sid, payload)
                onPromptRequested: (sid, text) => win.agentd.isBusy(sid) ? win.agentd.steer(sid, text) : win.agentd.sendPrompt(sid, text)
                onPrRequested: url => Qt.openUrlExternally(url)
                activityFor: sid => rail.fleetActivityColors(sid)
                activityLabelFor: sid => {
                  win.agentd.curToolGen
                  if (win.agentd.isInterrupting(sid)) return "stopping"
                  if (!win.agentd.isBusy(sid)) return rail.fleetActivityColors(sid).length ? "subagents" : "idle"
                  if (!win.agentd.curToolLiveFor(sid)) return "thinking"
                  var tool = win.agentd.curToolFor(sid).toLowerCase()
                  if (["edit", "write", "create", "str_replace", "bash-write"].includes(tool)) return "coding"
                  if (["read", "grep", "glob", "find", "ls", "ripgrep", "search_files"].includes(tool)) return "reading"
                  if (["bash", "shell"].includes(tool)) return "bash"
                  return tool || "thinking"
                }
                taskFor: sid => {
                  var feed = win.agentd.feedFor(sid)
                  for (var i = feed.length - 1; i >= 0; i--)
                    if (feed[i].taskTitle) return feed[i].taskTitle
                  return ""
                }
                onSessionRequested: sid => { win.pane = "rail"; rail.jumpToSession(sid) }
                enabled: win.dashboardActive
                onActiveFocusChanged: if (activeFocus) win.pane = "nvim"
                onFocusRequested: direction => win.tryFocus(direction)
                onActionRequested: actionId => {
                  if (!term.nvimSocket.length) return
                  Quickshell.execDetached(["nvim", "--server", term.nvimSocket, "--remote-expr",
                    'v:lua.require("cockpit").dashboard_action(' + JSON.stringify(actionId) + ')'])
                }
              }
            }
            Canvas {
              id: terminalCorner
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              width: paneLayout.terminalCornerRadius
              height: paneLayout.terminalCornerRadius
              z: 2
              readonly property color maskColor: win.ground
              onMaskColorChanged: requestPaint()
              onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                ctx.fillStyle = terminalCorner.maskColor
                ctx.beginPath()
                ctx.moveTo(width, 0)
                ctx.lineTo(width, height)
                ctx.lineTo(0, height)
                ctx.arc(0, 0, width, Math.PI / 2, 0, true)
                ctx.closePath()
                ctx.fill()
              }
            }
            Canvas {
              id: terminalTopCorner
              anchors.right: parent.right
              anchors.top: parent.top
              width: paneLayout.terminalCornerRadius
              height: paneLayout.terminalCornerRadius
              z: 2
              readonly property color maskColor: win.ground
              onMaskColorChanged: requestPaint()
              onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                ctx.fillStyle = terminalTopCorner.maskColor
                ctx.beginPath()
                ctx.moveTo(width, height)
                ctx.lineTo(width, 0)
                ctx.lineTo(0, 0)
                ctx.arc(0, height, width, -Math.PI / 2, 0, false)
                ctx.closePath()
                ctx.fill()
              }
            }
          }
          // The cockpit statusline (fed by nvim's chin bridge) — sits flush with the
          // window's true bottom edge, so the terminal grid's row slack hides at this
          // seam instead of rendering as a phantom row under an in-grid statusline.
          Chin {
            id: chin
            remoteSocket: term.nvimSocket !== term.localNvimSocket ? term.nvimSocket : ""
            switching: rail.switching
            width: parent.width
            height: parent.height - viewTabs.height - renderStack.height
            color: win.ground
          }
        }

        // Fill only the divider lane below the chin corner. Keeping this separate
        // prevents DPR overscan from extending the chin's hairline and right content.
        Rectangle {
          x: paneLayout.splitX
          y: parent.height - chin.height
          width: 1 + 2 / win.termDpr
          height: chin.height
          color: win.ground
        }

        // Divider stops at the chin's top hairline — the two meet in a clean
        // corner instead of the divider's tail running past it to the edge.
        Rectangle {
          id: divider
          x: rail.x - 1
          width: 1
          height: parent.height - chin.height
          opacity: win.railReveal
          color: win.ground
        }

        Rail {
          id: rail
          railGroundColor: win.ground
          width: parent.width - paneLayout.splitX - 1
          height: parent.height
          x: paneLayout.splitX + 1 + (1 - win.railReveal) * width
          opacity: win.railReveal
          enabled: !win.railCollapsed
          layer.enabled: win.railReveal > 0 && win.railReveal < 1
          layer.smooth: false
          agentd: win.modeReady ? win.agentd : null
          scopeMode: win.scopeMode
          instanceName: win.instanceName
          // One path per Cockpit instance, straight from the terminal that spawned nvim.
          nvimSock: term.nvimSocket
          localNvimSock: term.localNvimSocket
          reportedTab: viewTabs.reported
          remoteNvimSock: win.remoteEditorSocket
          onEditorRequested: socket => win.editorSocket = socket
          focused: win.pane === "rail"
          onFocusNvim: win.pane = "nvim"
          onRequestFocus: win.pane = "rail"
          onRequestScopeMode: mode => win.setScopeMode(mode)
          onActiveFocusChanged: if (activeFocus) win.pane = "rail"
          caretHeld: glideCaret.holding
        }

        // Focus moving between Neovim and the composer flies one caret across; the
        // arriving real cursor stays hidden until it lands.
        Item {
          id: glideCaret
          objectName: "focusGlideCaret"
          z: 100
          visible: caretGlide.running
          readonly property string owner: term.activeFocus ? "nvim" : dashboard.activeFocus ? "dashboard"
            : rail.composerField.activeFocus ? "composer" : rail.activeFocus ? "rail" : ""
          property string settled: ""
          property string settledKey: ""
          property bool wasEmpty: false
          property bool pending: false   // hides arriving cursors between the move and the glide's first frame
          readonly property bool holding: caretGlide.running || pending
          property string landing: "caret"   // caret: stretch into a line · rest: stay a dot · fade
          readonly property int dot: 8
          function leftSide(who) { return who === "nvim" || who === "dashboard" }
          function target(who, key) {
            if (who === "nvim" || who === "composer") {
              const r = who === "nvim" ? term.cursorRect : rail.composerField.cursorRectangle
              const item = who === "nvim" ? term : rail.composerField
              const p = item.mapToItem(paneLayout, r.x + r.width / 2, r.y + r.height / 2)
              return { x: p.x, y: p.y, h: Math.max(dot, r.height), landing: "caret" }
            }
            if (who === "rail") {
              const q = rail.cursorPoint(key || rail.cursorKey)
              if (!q) return null
              const p = rail.mapToItem(paneLayout, q.x, q.y)
              return { x: p.x, y: p.y, h: dot, landing: "rest" }
            }
            const tab = viewTabRepeater.itemAt(viewTabs.views.indexOf(viewTabs.current))
            if (!tab) return null
            const p = tab.mapToItem(paneLayout, 24, tab.height / 2)
            return { x: p.x, y: p.y, h: dot, landing: "fade" }
          }
          onOwnerChanged: {
            if (!owner) { wasEmpty = true; focusGap.restart(); return }
            if (settled && !(leftSide(owner) && leftSide(settled))) pending = true
            Qt.callLater(settle)
          }
          Connections { target: rail; function onCursorKeyChanged() {
              if (glideCaret.owner !== "rail") return
              glideCaret.pending = true
              Qt.callLater(glideCaret.settle)
            } }
          // Deferred a tick: entering the rail may hop straight on into the composer.
          function settle() {
            if (!owner) { pending = false; return }
            const key = owner === "rail" ? rail.cursorKey : ""
            const moved = owner !== settled ? !(leftSide(owner) && leftSide(settled)) : key !== settledKey
            const flying = moved && caretGlide.running
            if (flying) caretGlide.stop()   // animators write their current value back on stop
            const from = settled && moved ? (flying ? { x: x, y: y, h: dot, landing: "rest" } : target(settled, settledKey)) : null
            const to = from ? target(owner) : null
            if (from && to && (!wasEmpty || focusGap.running)) {
              fromLine.height = from.h; toLine.height = to.h
              fromFade.from = from.landing === "caret" ? 1 : 0
              dotIn.from = dotInScale.from = from.landing === "rest" ? 1 : 0.25
              landing = to.landing
              const dx = to.x - from.x, dy = to.y - from.y
              glideTail.width = Math.min(140, Math.hypot(dx, dy) * 0.2)
              glideTail.rotation = Math.atan2(dy, dx) * 180 / Math.PI
              glideX.from = from.x; glideX.to = to.x
              glideY.from = from.y; glideY.to = to.y
              caretGlide.start()
            }
            focusGap.stop()
            wasEmpty = false
            pending = false
            settled = owner; settledKey = key
          }
          Timer { id: focusGap; interval: 100 }
          Rectangle { id: fromLine; x: -1; y: -height / 2; width: 2; radius: 1; color: Theme.cursor; opacity: 0 }
          Rectangle { id: toLine; x: -1; y: -height / 2; width: 2; radius: 1; color: Theme.cursor; opacity: 0 }
          // Motion streak: a fast 8px dot strobes into separate copies; the tail bridges them.
          Rectangle {
            id: glideTail
            x: -width; y: -height / 2
            height: glideCaret.dot; radius: height / 2
            transformOrigin: Item.Right
            opacity: 0
            gradient: Gradient {
              orientation: Gradient.Horizontal
              GradientStop { position: 0; color: Qt.alpha(Theme.cursor, 0) }
              GradientStop { position: 1; color: Theme.cursor }
            }
          }
          Rectangle {
            id: glideDot
            x: -width / 2; y: -height / 2
            width: glideCaret.dot; height: width; radius: width / 2
            color: Theme.cursor; opacity: 0
          }
          // Line pinches into a dot, flies, then stretches back into a line: all render-thread
          // animators (a same-value animator stands in for a pause) so nothing else can stall it.
          ParallelAnimation {
            id: caretGlide
            XAnimator { id: glideX; target: glideCaret; duration: 180; easing.type: Easing.InOutSine }
            YAnimator { id: glideY; target: glideCaret; duration: 180; easing.type: Easing.InOutSine }
            OpacityAnimator { id: fromFade; target: fromLine; from: 1; to: 0; duration: 50; easing.type: Easing.InQuad }
            ScaleAnimator { target: fromLine; from: 1; to: glideCaret.dot / fromLine.height; duration: 50; easing.type: Easing.InCubic }
            SequentialAnimation {
              ParallelAnimation {
                OpacityAnimator { id: dotIn; target: glideDot; from: 0; to: 1; duration: 45; easing.type: Easing.OutQuad }
                ScaleAnimator { id: dotInScale; target: glideDot; from: 0.25; to: 1; duration: 50; easing.type: Easing.OutCubic }
              }
              OpacityAnimator { target: glideDot; from: 1; to: 1; duration: 50 }
              ParallelAnimation {
                OpacityAnimator { target: glideDot; from: 1; to: glideCaret.landing === "rest" ? 1 : 0; duration: 80; easing.type: Easing.InQuad }
                ScaleAnimator { target: glideDot; from: 1; to: glideCaret.landing === "rest" ? 1 : 0.25; duration: 80; easing.type: Easing.InOutCubic }
              }
            }
            SequentialAnimation {
              OpacityAnimator { target: glideTail; from: 0; to: 0; duration: 25 }
              OpacityAnimator { target: glideTail; from: 0; to: 0.8; duration: 50; easing.type: Easing.OutQuad }
              OpacityAnimator { target: glideTail; from: 0.8; to: 0; duration: 80; easing.type: Easing.InQuad }
            }
            SequentialAnimation {
              OpacityAnimator { target: toLine; from: 0; to: 0; duration: 110 }
              ParallelAnimation {
                OpacityAnimator { target: toLine; from: 0; to: glideCaret.landing === "caret" ? 1 : 0; duration: 60; easing.type: Easing.OutQuad }
                ScaleAnimator { target: toLine; from: glideCaret.dot / toLine.height; to: 1; duration: 70; easing.type: Easing.OutCubic }
              }
            }
          }
        }
      }
    }
  }
}

import QtQuick
import Quickshell
import Quickshell.Io
import QsLib
import Heidr

// Cockpit: nvim (libghostty terminal) left, the agent rail right.
// Super+h/l focus moves nvim <-> rail via the IpcHandler below (niri calls it,
// falling back to window-focus at the edges — the "smart-splits" bridge).
ShellRoot {
  FloatingWindow {
    id: win
    // Per-mode title lets both Cockpit instances coexist and keeps focused-window IPC routing exact.
    title: Quickshell.env("COCKPIT_TITLE") || Quickshell.env("HEIDR_TITLE") || "cockpit-qs"
    visible: true       // match mlqs — a cold-started FloatingWindow must map explicitly
    // Wide by default: the cockpit is two panes (nvim ~60% + rail ~40%), so 1600
    // left the terminal too narrow for real code once the rail took its share.
    implicitWidth: 2400
    implicitHeight: 1300
    minimumSize: Qt.size(640, 400)   // let niri's set-column-width actually shrink it
    onClosed: Qt.quit()              // niri close-window quits (FloatingWindow ignores it otherwise)

    property string pane: "nvim"   // "nvim" | "rail"
    readonly property bool dashboardActive: !!(chin.st.dashboard && chin.st.dashboard.active)

    readonly property bool windowFocused: term.activeFocus || dashboard.activeFocus || rail.activeFocus
    function syncPresence() {
      agentd.setPresence(windowFocused ? rail.selectedRaw : "")
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
      // Parent binding for the pane's nvim: its NVIM_LISTEN_ADDRESS is unique to THIS
      // instance, so cockpit-cross can target its own Cockpit without asking niri anything.
      function nvimSock(): string   { return term.nvimSocket }
      function attachAgentd(path: string): string { return agentd.attachSocket(path) ? "ok" : "rejected" }
      function focusRoster(): string { win.pane = "rail"; rail.focusRoster(); return "ok" }
      // Super+i ask-jump: land on the session that needs an answer.
      function selectSession(n: string): string { win.pane = "rail"; rail.jumpToSession(n); return "ok" }
      // `i` on the nvim dashboard: jump straight into the rail composer instead of
      // erroring on the read-only buffer. callLater lets the pane switch settle first.
      function focusComposer(): string { win.pane = "rail"; Qt.callLater(rail.enterInsert); return "ok" }
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
                                sel: rail.selectedRaw, key: rail.cursorKey,
                                ins: rail.insert, ask: !!rail.pendingAsk, stale: !!rail.staleAsk,
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
                                pane: win.pane })
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
        for (var i = 0; i < agentd.sessions.length; i++) {
          var s = agentd.sessions[i]
          out.push((s.scope || "?") + "/" + s.name + " " + (s.status || "?"))
        }
        return out.length ? out.join("\n") : "(empty)"
      }
    }

    // Mirrored off the terminal so its own width/height bindings never reference a
    // property of the item they are sizing — that self-reference resolved late and left
    // the width unsnapped while the height snapped correctly.
    readonly property real termDpr: term.dpr > 0 ? term.dpr : 1

    AgentdState { id: agentd; scope: "lovable" }

    Rectangle {
      anchors.fill: parent
      // bgDim, not bg: the term column's dpr-snapped width is fractional, so a
      // sub-pixel seam of this root can peek out at the term/rail boundary —
      // in bg (white on light) that read as a stray white line. Every child
      // paints its own ground, so the root only ever shows in seams.
      color: Theme.bgDim

      Row {
        anchors.fill: parent

        Column {
          id: termCol
          width: Math.round(parent.width * 0.6 * win.termDpr) / win.termDpr
          height: parent.height
          Item {
            id: renderStack
            width: parent.width
            height: Math.round((parent.height - chin.implicitHeight) * win.termDpr) / win.termDpr

            Crossfade {
              anchors.fill: parent
              showSecond: win.dashboardActive
              enterDuration: 400
              exitDuration: 350
              shift: 8
              first: TermView {
                id: term
                anchors.fill: parent
                active: activeFocus && !win.dashboardActive
                enabled: !win.dashboardActive
                Component.onCompleted: forceActiveFocus()
                onActiveFocusChanged: if (activeFocus) win.pane = "nvim"
              }
              second: Dashboard {
                id: dashboard
                anchors.fill: parent
                model: (chin.st.dashboard && chin.st.dashboard.model) || ({})
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
          }
          // The cockpit statusline (fed by nvim's chin bridge) — sits flush with the
          // window's true bottom edge, so the terminal grid's row slack hides at this
          // seam instead of rendering as a phantom row under an in-grid statusline.
          Chin {
            id: chin
            width: parent.width
            height: parent.height - renderStack.height
          }
        }

        // Divider stops at the chin's top hairline — the two meet in a clean
        // corner instead of the divider's tail running past it to the edge.
        Rectangle { width: 1; height: parent.height - chin.height; color: Theme.hairline }

        Rail {
          id: rail
          width: parent.width - termCol.width - 1
          height: parent.height
          agentd: agentd
          // One path per Cockpit instance, straight from the terminal that spawned nvim.
          nvimSock: term.nvimSocket
          focused: win.pane === "rail"
          onFocusNvim: win.pane = "nvim"
          onRequestFocus: win.pane = "rail"
          onActiveFocusChanged: if (activeFocus) win.pane = "rail"
        }
      }
    }
  }
}

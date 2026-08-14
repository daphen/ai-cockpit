import QtQuick
import Quickshell
import Quickshell.Io
import QsLib
import Heidr

// Heidr cockpit: nvim (libghostty terminal) left, the agent rail right.
// Super+h/l focus moves nvim <-> rail via the IpcHandler below (niri calls it,
// falling back to window-focus at the edges — the "smart-splits" bridge).
ShellRoot {
  FloatingWindow {
    id: win
    // Per-mode title (launcher sets HEIDR_TITLE: "heidr-qs · lovable" / "heidr-qs · private")
    // so two instances can coexist: niri-jump-or-exec cycles every "heidr-qs" match, and
    // heidr-ipc routes to the instance whose title equals the FOCUSED window's.
    title: Quickshell.env("HEIDR_TITLE") || "heidr-qs"
    visible: true       // match mlqs — a cold-started FloatingWindow must map explicitly
    // Wide by default: the cockpit is two panes (nvim ~60% + rail ~40%), so 1600
    // left the terminal too narrow for real code once the rail took its share.
    implicitWidth: 2400
    implicitHeight: 1300
    minimumSize: Qt.size(640, 400)   // let niri's set-column-width actually shrink it
    onClosed: Qt.quit()              // niri close-window quits (FloatingWindow ignores it otherwise)

    property string pane: "nvim"   // "nvim" | "rail"

    // Returns "consumed" if it moved internal focus, "passed" if already at the
    // edge (the niri script then does its normal window focus).
    function tryFocus(dir) {
      // Heal a pane/focus desync first: a QML hot-reload rebuilds the window tree and
      // can leave `pane` claiming the rail while the keyboard truly sits in the
      // terminal — the cross then answers "passed" and Ctrl+l goes dead. Reality wins.
      if (term.activeFocus && win.pane !== "nvim") win.pane = "nvim"
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
      if (win.pane === "nvim") term.forceActiveFocus()
      else rail.forceActiveFocus()
    }

    IpcHandler {
      target: "heidr"
      function focusLeft(): string  { return win.tryFocus("left") }
      function focusRight(): string { return win.tryFocus("right") }
      function pane(): string {
        // Report reality, not the cached property: hot-reloads leave win.pane stale
        // ("rail" while the keyboard truly sits in the terminal), and Super+T's
        // "already on the rail?" check then hopped cockpits straight from the terminal.
        if (term.activeFocus && win.pane !== "nvim") win.pane = "nvim"
        return win.pane
      }
      function title(): string      { return win.title }   // heidr-ipc instance routing
      // Parent binding for the pane's nvim: its NVIM_LISTEN_ADDRESS is unique to THIS
      // instance, so heidr-cross can target its own heidr without asking niri anything.
      function nvimSock(): string   { return term.nvimSocket }
      function focusRoster(): string { win.pane = "rail"; rail.focusRoster(); return "ok" }
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
                                keys: rail.keyLog, lastCancel: rail.lastCancel,
                                pCards: rail.probeCardCreates, pDots: rail.probeDotCreates, pResets: rail.probeFullResets, pActs: rail.probeActCreates, im: rail.imode,
                                row: rail.curRowText() })
      }
      function railKey(k: string): string { rail.debugNav(k); return "ok" }
      // Rendered prose of the focused feed row — what the user actually SEES,
      // after the badge/hint/colorize pipeline (test probe).
      function railProse(): string { return rail.probeProse() }
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
      // when several sockets are wired up (HEIDR_AGENTD_SOCKS).
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
      color: Theme.bg

      Row {
        anchors.fill: parent

        TermView {
          id: term
          // Device-pixel EXACT size. The offscreen frame is ceil(w*dpr) wide and the
          // paint texture is too, so unless w*dpr is a whole number the painter's scale
          // is ceil(w*dpr)/w rather than dpr and every blit resamples the frame by ~1+ε.
          // With smoothing off that is nearest-neighbour, which is what made glyph stems
          // uneven — some crisp, some smeared. Snapping the item removes the mismatch.
          // term.dpr comes from the widget itself (window()->effectiveDevicePixelRatio()),
          // because QML's Screen.devicePixelRatio reported 1 while the window ran at 1.75.
          width: Math.round(parent.width * 0.6 * win.termDpr) / win.termDpr
          height: Math.round(parent.height * win.termDpr) / win.termDpr
          // Focus is managed IMPERATIVELY (onPaneChanged + click). A `focus:`
          // binding here fights forceActiveFocus and leaves the terminal unable
          // to hold keyboard focus — same lesson the rail notes for itself.
          active: activeFocus   // show the block cursor only while the terminal truly holds focus
          Component.onCompleted: forceActiveFocus()
          // Keep pane in sync when focus is grabbed by a click (not just Ctrl+h/l),
          // else tryFocus() sees a stale pane and the C-l/C-h cross no-ops.
          onActiveFocusChanged: if (activeFocus) win.pane = "nvim"
        }

        Rectangle { width: 1; height: parent.height; color: Theme.hairline }

        Rail {
          id: rail
          width: parent.width - term.width - 1
          height: parent.height
          agentd: agentd
          // One path per heidr instance, straight from the terminal that spawned nvim.
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

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
    title: "heidr-qs"   // unique — the old nvim cockpit window title contains "heidr"
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
      function pane(): string       { return win.pane }
      function focusRoster(): string { win.pane = "rail"; rail.focusRoster(); return "ok" }
      // The rail's test interface (test/rail-nav.sh): cursor/scroll behaviour depends on
      // the roster and feed changing UNDER the cursor, which is only assertable from
      // outside the process.
      function railState(): string {
        return JSON.stringify({ cur: rail.cur, rSize: rail.rSize, navTotal: rail.navTotal,
                                view: rail.view, mode: rail.scrollMode,
                                sel: rail.selectedRaw, key: rail.cursorKey })
      }
      function railKey(k: string): string { rail.debugNav(k); return "ok" }
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
          focused: win.pane === "rail"
          onFocusNvim: win.pane = "nvim"
          onRequestFocus: win.pane = "rail"
          onActiveFocusChanged: if (activeFocus) win.pane = "rail"
        }
      }
    }
  }
}

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

    AgentdState { id: agentd; scope: "lovable" }

    Rectangle {
      anchors.fill: parent
      color: Theme.bg

      Row {
        anchors.fill: parent

        TermView {
          id: term
          width: Math.round(parent.width * 0.6)
          height: parent.height
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

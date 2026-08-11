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
    implicitWidth: 1600
    implicitHeight: 950

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
          focus: win.pane === "nvim"
          active: win.pane === "nvim"   // hide the terminal cursor when the rail has focus
          Component.onCompleted: forceActiveFocus()
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
        }
      }
    }
  }
}

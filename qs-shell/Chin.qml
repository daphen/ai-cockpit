import QtQuick
import Quickshell
import Quickshell.Io
import QsLib

// The cockpit's statusline: renders the state nvim pushes via cockpit/chin.lua
// (a watched JSON file, one per cockpit mode). Replaces lualine inside the
// cockpit so the bar sits flush with the true window edge — grid slack hides at
// the term/chin seam instead of reading as a phantom row under a statusline.
Rectangle {
  id: chin
  implicitHeight: 30
  color: Theme.bgDim

  property var st: ({})
  readonly property string scope: {
    var s = Quickshell.env("COCKPIT_SCOPE") || Quickshell.env("HEIDR_SCOPE")
    return s || "personal"
  }
  function _n(v) { return typeof v === "number" ? v : 0 }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/cockpit/chin-" + chin.scope + ".json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      try { chin.st = JSON.parse(String(text())) } catch (e) { /* partial write; next change reloads */ }
    }
  }

  Rectangle { anchors { top: parent.top; left: parent.left; right: parent.right } height: 1; color: Theme.hairline }

  Row {
    anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
    spacing: 10
    Rectangle {
      radius: 6
      width: modeText.implicitWidth + 14; height: 20
      anchors.verticalCenter: parent.verticalCenter
      color: {
        var m = String(chin.st.mode || "")
        if (m === "INSERT") return Theme.electric
        if (m.indexOf("V") === 0 || m === "SELECT") return Theme.orange
        if (m === "COMMAND" || m === "REPLACE") return Theme.red
        return Theme.surface0
      }
      Text {
        id: modeText
        anchors.centerIn: parent
        text: String(chin.st.mode || "NORMAL")
        color: String(chin.st.mode || "") === "NORMAL" ? Theme.fg_muted : Theme.bg
        font { family: Theme.fontFamily; pixelSize: 11; bold: true }
      }
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: String(chin.st.path || "")
      color: Theme.fg
      font { family: Theme.fontFamily; pixelSize: 12 }
      elide: Text.ElideMiddle
      // Leave the right cluster its room; the path is the only elastic piece.
      width: Math.min(implicitWidth, chin.width - right.implicitWidth - modeText.implicitWidth - 80)
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: !!chin.st.ft
      text: String(chin.st.ft || "")
      color: Theme.fg_muted
      font { family: Theme.fontFamily; pixelSize: 11 }
    }
  }

  Row {
    id: right
    anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
    spacing: 12
    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: !!chin.st.branch
      text: " " + String(chin.st.branch || "")
      color: Theme.fg_muted
      font { family: Theme.fontFamily; pixelSize: 11 }
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: chin._n(chin.st.add) + chin._n(chin.st.chg) + chin._n(chin.st.del) > 0
      text: (chin._n(chin.st.add) ? "+" + chin.st.add + " " : "")
          + (chin._n(chin.st.chg) ? "~" + chin.st.chg + " " : "")
          + (chin._n(chin.st.del) ? "−" + chin.st.del : "")
      color: Theme.fg_muted
      font { family: Theme.fontFamily; pixelSize: 11 }
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: chin._n(chin.st.err) + chin._n(chin.st.warn) > 0
      text: (chin._n(chin.st.err) ? "✗" + chin.st.err + " " : "") + (chin._n(chin.st.warn) ? "▲" + chin.st.warn : "")
      color: chin._n(chin.st.err) > 0 ? Theme.red : Theme.fg_muted
      font { family: Theme.fontFamily; pixelSize: 11 }
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: !!chin.st.plan
      text: String(chin.st.plan || "")
      color: Theme.electric
      font { family: Theme.fontFamily; pixelSize: 11 }
    }
  }
}

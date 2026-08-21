import QtQuick
import Quickshell
import Quickshell.Io
import QsLib

// The cockpit's statusline: renders the state nvim pushes via cockpit/chin.lua
// (a watched JSON file, one per cockpit mode). Mirrors the retired lualine
// layout — left: path+modified · diagnostics · searchcount; middle: macro pill;
// right: filetype · worktree diff · plan chip · ticket chip · scrollbar glyph.
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
  // lualine's scroll-timeline glyph: position within the buffer, doubled.
  readonly property var _sbar: ["▔", "🮂", "🬂", "🮃", "▀", "▄", "▃", "🬭", "▂", "▁"]
  function scrollGlyph() {
    var lines = _n(st.lines); if (lines < 1) return ""
    var i = Math.min(_sbar.length - 1, Math.floor((_n(st.line) - 1) / lines * _sbar.length))
    return _sbar[i] + _sbar[i]
  }

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
    id: left
    anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
    spacing: 10
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: String(chin.st.path || "")
      color: Theme.fg
      font { family: Theme.fontFamily; pixelSize: 12 }
      elide: Text.ElideMiddle
      width: Math.min(implicitWidth, chin.width - right.implicitWidth - 120)
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: chin._n(chin.st.err) > 0
      text: "✗ " + chin.st.err
      color: Theme.red
      font { family: Theme.fontFamily; pixelSize: 11 }
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: chin._n(chin.st.warn) > 0
      text: "▲ " + chin.st.warn
      color: Theme.yellow
      font { family: Theme.fontFamily; pixelSize: 11 }
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: chin._n(chin.st.info) > 0
      text: "● " + chin.st.info
      color: Theme.sky
      font { family: Theme.fontFamily; pixelSize: 11 }
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: !!chin.st.search
      text: String(chin.st.search || "")
      color: Theme.fg_muted
      font { family: Theme.fontFamily; pixelSize: 11 }
    }
    // Macro-recording pill — lualine's red REC block.
    Rectangle {
      visible: !!chin.st.rec
      radius: 4
      width: recText.implicitWidth + 12; height: 18
      anchors.verticalCenter: parent.verticalCenter
      color: Theme.red
      Text {
        id: recText
        anchors.centerIn: parent
        text: "REC @" + String(chin.st.rec || "").toUpperCase()
        color: Theme.bg
        font { family: Theme.fontFamily; pixelSize: 10; bold: true }
      }
    }
  }

  Row {
    id: right
    anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
    spacing: 12
    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: !!chin.st.ft
      text: String(chin.st.ft || "")
      color: Theme.fg_muted
      font { family: Theme.fontFamily; pixelSize: 11 }
    }
    Row {
      anchors.verticalCenter: parent.verticalCenter
      visible: chin._n(chin.st.add) + chin._n(chin.st.del) > 0
      spacing: 6
      Text {
        visible: chin._n(chin.st.add) > 0
        text: "+" + chin.st.add
        color: Theme.green
        font { family: Theme.fontFamily; pixelSize: 11 }
      }
      Text {
        visible: chin._n(chin.st.del) > 0
        text: "−" + chin.st.del
        color: Theme.red
        font { family: Theme.fontFamily; pixelSize: 11 }
      }
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: !!chin.st.plan
      text: String(chin.st.plan || "")
      color: Theme.electric
      font { family: Theme.fontFamily; pixelSize: 11 }
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: !!chin.st.root
      text: " " + String(chin.st.root || "")
      color: Theme.fg_muted
      font { family: Theme.fontFamily; pixelSize: 11 }
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: chin.scrollGlyph()
      color: Theme.red
      font { family: Theme.fontFamily; pixelSize: 11 }
    }
  }
}

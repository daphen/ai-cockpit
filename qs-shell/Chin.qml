import QtQuick
import Quickshell
import Quickshell.Io
import QsLib

// The cockpit's statusline: renders the state nvim pushes via cockpit/chin.lua
// (a watched JSON file, one per cockpit instance). Mirrors the retired lualine
// layout — left: path+modified · diagnostics · searchcount · REC pill;
// right: filetype · worktree diff · plan chip · ticket chip · scrollbar glyph —
// but animated: values crossfade (out-up / in-from-below), numbers pop, and
// items glide open/closed instead of hard-cutting, since the chin lives in QML
// where lualine could only repaint cells.
Rectangle {
  id: chin
  implicitHeight: 36
  color: Theme.bgDim

  property var st: ({})
  readonly property string instanceName: Quickshell.env("COCKPIT_INSTANCE")
      || Quickshell.env("HEIDR_INSTANCE") || "main"
  function _n(v) { return typeof v === "number" ? v : 0 }

  // Animated value cell: crossfades text changes (old rises out, new enters from
  // below), pops numbers when `pop`, and glides its width — including its own
  // trailing gap — to zero when empty, so neighbors reflow smoothly.
  component Swap: Item {
    id: sw
    property string value: ""
    property color tint: Theme.fg
    property int px: 16
    property bool bold: false
    property bool pop: false
    property real gap: 14
    clip: true
    height: ta.implicitHeight + 8
    // REACTIVE width: an imperative snapshot of implicitWidth desynced when the
    // custom font settled late (creation-time metrics underestimated, neighbors
    // started early and rows mashed together). A binding tracks font/layout.
    readonly property Item _active: _front ? ta : tb
    width: value.length ? _active.implicitWidth + gap : 0
    Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    property bool _front: true
    onValueChanged: {
      var inc = _front ? tb : ta
      inc.text = value
      _front = !_front
    }
    Crossfade {
      anchors.fill: parent
      showSecond: !sw._front
      inactiveScale: sw.pop ? 1.25 : 1
      first: Text {
        id: ta
        color: sw.tint; font { family: Theme.fontFamily; pixelSize: sw.px; bold: sw.bold }
        anchors.verticalCenter: parent.verticalCenter
      }
      second: Text {
        id: tb
        color: sw.tint; font { family: Theme.fontFamily; pixelSize: sw.px; bold: sw.bold }
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  component DiffStat: Item {
    id: stat
    property string icon: ""
    property int value: 0
    property color tint: Theme.fg
    visible: value > 0
    implicitWidth: body.implicitWidth + 8
    implicitHeight: 18
    Row {
      id: body
      anchors.verticalCenter: parent.verticalCenter
      spacing: 4
      Icon { name: stat.icon; width: 14; height: 14; color: stat.tint; anchors.verticalCenter: parent.verticalCenter }
      Text {
        text: String(stat.value)
        color: stat.tint
        font { family: Theme.fontFamily; pixelSize: 16; bold: true }
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/cockpit/chin-" + chin.instanceName + ".json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      try { chin.st = JSON.parse(String(text())) } catch (e) { /* partial write; next change reloads */ }
    }
  }

  Rectangle { anchors { top: parent.top; left: parent.left; right: parent.right } height: 1; color: Theme.hairline }

  Row {
    id: left
    anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
    spacing: 0
    height: parent.height
    Swap { anchors.verticalCenter: parent.verticalCenter
           value: String(chin.st.path || ""); tint: Theme.fg; bold: true }
    Swap { anchors.verticalCenter: parent.verticalCenter; pop: true
           value: chin._n(chin.st.err)  > 0 ? "✗ " + chin.st.err  : ""; tint: Theme.red }
    Swap { anchors.verticalCenter: parent.verticalCenter; pop: true
           value: chin._n(chin.st.warn) > 0 ? "▲ " + chin.st.warn : ""; tint: Theme.yellow }
    Swap { anchors.verticalCenter: parent.verticalCenter; pop: true
           value: chin._n(chin.st.info) > 0 ? "● " + chin.st.info : ""; tint: Theme.sky }
    Swap { anchors.verticalCenter: parent.verticalCenter
           value: String(chin.st.search || ""); tint: Theme.fg_muted }
    // Macro-recording pill — lualine's red REC block, popping in/out.
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      radius: 4
      width: recText.implicitWidth + 14; height: 24
      color: Theme.red
      opacity: chin.st.rec ? 1 : 0
      scale: chin.st.rec ? 1 : 0.6
      visible: opacity > 0.01
      Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
      Behavior on scale   { NumberAnimation { duration: 220; easing.type: Easing.OutBack } }
      Text {
        id: recText
        anchors.centerIn: parent
        text: "REC @" + String(chin.st.rec || "").toUpperCase()
        color: Theme.bg
        font { family: Theme.fontFamily; pixelSize: 16; bold: true }
      }
    }
  }

  Row {
    id: right
    anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
    spacing: 0
    height: parent.height
    // Wrapper reserves 6px of air after the glyph (Icon stretches to its
    // width, so padding must live outside it).
    Item {
      anchors.verticalCenter: parent.verticalCenter
      width: visible ? 22 : 0
      height: 16
      visible: String(chin.st.ft || "").length > 0
      Icon {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        name: "file-content"
        color: Theme.fg_muted
        width: 16
        height: 16
      }
    }
    Swap { anchors.verticalCenter: parent.verticalCenter
           value: String(chin.st.ft || ""); tint: Theme.fg_muted }
    DiffStat { anchors.verticalCenter: parent.verticalCenter; icon: "square-plus"; value: chin._n(chin.st.add); tint: Theme.green }
    DiffStat { anchors.verticalCenter: parent.verticalCenter; icon: "square-minus"; value: chin._n(chin.st.del); tint: Theme.red }
    Swap { anchors.verticalCenter: parent.verticalCenter
           value: String(chin.st.plan || ""); tint: Theme.fg }
    Swap { anchors.verticalCenter: parent.verticalCenter
           value: chin.st.root ? " " + chin.st.root : ""; tint: Theme.fg }
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: 18; height: 18; radius: 5
      color: Theme.surface0
      border.width: 1
      border.color: Theme.hairline
      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        width: 10; height: 2
        color: Theme.orange
        readonly property real targetY: 2 + (parent.height - height - 4)
          * (chin._n(chin.st.lines) > 1 ? (chin._n(chin.st.line) - 1) / (chin._n(chin.st.lines) - 1) : 0)
        property real animatedY: targetY
        y: Math.round(animatedY)
        Behavior on animatedY { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      }
    }
  }
}

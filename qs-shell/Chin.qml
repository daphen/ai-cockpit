import QtQuick
import Quickshell
import Quickshell.Io
import QsLib

// The cockpit's statusline: renders the state nvim pushes via cockpit/chin.lua
// (a watched JSON file, one per cockpit mode). Mirrors the retired lualine
// layout — left: path+modified · diagnostics · searchcount · REC pill;
// right: filetype · worktree diff · plan chip · ticket chip · scrollbar glyph —
// but animated: values crossfade (out-up / in-from-below), numbers pop, and
// items glide open/closed instead of hard-cutting, since the chin lives in QML
// where lualine could only repaint cells.
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

  // Animated value cell: crossfades text changes (old rises out, new enters from
  // below), pops numbers when `pop`, and glides its width — including its own
  // trailing gap — to zero when empty, so neighbors reflow smoothly.
  component Swap: Item {
    id: sw
    property string value: ""
    property color tint: Theme.fg
    property int px: 11
    property bool pop: false
    property real gap: 10
    clip: true
    height: ta.implicitHeight + 8
    width: _w
    property real _w: 0
    Behavior on _w { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    property bool _front: true
    onValueChanged: {
      var inc = _front ? tb : ta
      var out = _front ? ta : tb
      _front = !_front
      if (value.length) {
        inc.text = value
        _w = inc.implicitWidth + gap
        inAnimFor(inc).restart()
      } else {
        _w = 0
      }
      outAnimFor(out).restart()
    }
    function inAnimFor(t)  { return t === ta ? aIn  : bIn }
    function outAnimFor(t) { return t === ta ? aOut : bOut }
    Text {
      id: ta
      color: sw.tint; font { family: Theme.fontFamily; pixelSize: sw.px }
      anchors.verticalCenter: parent.verticalCenter
      opacity: 0
      transformOrigin: Item.Center
    }
    Text {
      id: tb
      color: sw.tint; font { family: Theme.fontFamily; pixelSize: sw.px }
      anchors.verticalCenter: parent.verticalCenter
      opacity: 0
      transformOrigin: Item.Center
    }
    ParallelAnimation {
      id: aIn
      NumberAnimation { target: ta; property: "opacity"; from: 0; to: 1; duration: 180; easing.type: Easing.OutCubic }
      NumberAnimation { target: ta; property: "anchors.verticalCenterOffset"; from: 7; to: 0; duration: 180; easing.type: Easing.OutCubic }
      NumberAnimation { target: ta; property: "scale"; from: sw.pop ? 1.25 : 1; to: 1; duration: 220; easing.type: Easing.OutBack }
    }
    ParallelAnimation {
      id: aOut
      NumberAnimation { target: ta; property: "opacity"; to: 0; duration: 140; easing.type: Easing.InCubic }
      NumberAnimation { target: ta; property: "anchors.verticalCenterOffset"; to: -7; duration: 140; easing.type: Easing.InCubic }
    }
    ParallelAnimation {
      id: bIn
      NumberAnimation { target: tb; property: "opacity"; from: 0; to: 1; duration: 180; easing.type: Easing.OutCubic }
      NumberAnimation { target: tb; property: "anchors.verticalCenterOffset"; from: 7; to: 0; duration: 180; easing.type: Easing.OutCubic }
      NumberAnimation { target: tb; property: "scale"; from: sw.pop ? 1.25 : 1; to: 1; duration: 220; easing.type: Easing.OutBack }
    }
    ParallelAnimation {
      id: bOut
      NumberAnimation { target: tb; property: "opacity"; to: 0; duration: 140; easing.type: Easing.InCubic }
      NumberAnimation { target: tb; property: "anchors.verticalCenterOffset"; to: -7; duration: 140; easing.type: Easing.InCubic }
    }
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
    spacing: 0
    height: parent.height
    Swap { anchors.verticalCenter: parent.verticalCenter
           value: String(chin.st.path || ""); tint: Theme.fg; px: 12 }
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
      width: recText.implicitWidth + 12; height: 18
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
        font { family: Theme.fontFamily; pixelSize: 10; bold: true }
      }
    }
  }

  Row {
    id: right
    anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
    spacing: 0
    height: parent.height
    Swap { anchors.verticalCenter: parent.verticalCenter
           value: String(chin.st.ft || ""); tint: Theme.fg_muted }
    // The old lualine fancy_diff nerd glyphs, not bare +/-.
    Swap { anchors.verticalCenter: parent.verticalCenter; pop: true; gap: 6
           value: chin._n(chin.st.add) > 0 ? " " + chin.st.add : ""; tint: Theme.green }
    Swap { anchors.verticalCenter: parent.verticalCenter; pop: true
           value: chin._n(chin.st.del) > 0 ? " " + chin.st.del : ""; tint: Theme.red }
    Swap { anchors.verticalCenter: parent.verticalCenter
           value: String(chin.st.plan || ""); tint: Theme.fg_muted }
    Swap { anchors.verticalCenter: parent.verticalCenter
           value: chin.st.root ? " " + chin.st.root : ""; tint: Theme.fg_muted }
    // Scroll position as a real track: the thumb slides over the unscrolled
    // remainder — a proper miniature scrollbar, not lualine's glyph cell.
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      // Wide like the old lualine glyph cell (two block chars), not a skinny bar.
      width: 16; height: 18; radius: 3
      color: Theme.surface0
      border.width: 1
      border.color: Theme.hairline
      Rectangle {
        width: parent.width; height: 5; radius: 2.5
        // The special scroll-timeline red lualine used, not the theme red.
        color: "#ED333B"
        y: (parent.height - height)
           * (chin._n(chin.st.lines) > 1 ? (chin._n(chin.st.line) - 1) / (chin._n(chin.st.lines) - 1) : 0)
        Behavior on y { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      }
    }
  }
}

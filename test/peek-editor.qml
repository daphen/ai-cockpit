import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import QsLib
import "."

ShellRoot {
  id: test
  property int closes: 0
  readonly property string file: Quickshell.env("HOME") + "/peek.txt"
  function fail(message) { console.error("Error: " + message); Qt.quit() }
  function ask(args, done) { probe.done = done; probe.command = ["nvim", "--server", peek.socket].concat(args); probe.running = true }
  FileView { id: sample; path: test.file; blockWrites: true; blockLoading: true }
  Process {
    id: probe
    property var done: null
    stdout: StdioCollector { onStreamFinished: if (probe.done) probe.done(this.text.trim()) }
  }
  FloatingWindow {
    visible: true; implicitWidth: 900; implicitHeight: 700
    PeekEditor {
      id: peek
      anchors.fill: parent
      instanceName: "peek-test"
      warm: true
      onClosed: test.closes++
    }
  }
  Timer {
    property int stage: 0
    property int waits: 0
    interval: 300; repeat: true; running: true
    onTriggered: {
      if (stage === 0) {
        sample.setText(Array.from({ length: 60 }, (_, i) => "line " + (i + 1)).join("\n") + "\n")
      } else if (stage === 1) {
        peek.show({ path: test.file, alternate: "" }, 42)
        if (!peek.open || !peek.visible) test.fail("show should open the floating editor")
      } else if (stage === 2) {
        running = false
        test.ask(["--remote-expr", 'bufname() .. ":" .. line(".") .. ":" .. &readonly'], out => {
          if (out !== test.file + ":42:0") { if (++waits < 20) { running = true; return } test.fail("the peek should show the file editable at line 42, got " + out) }
          waits = 0
          test.ask(["--remote-send", "ccedited<Esc>q"], () => { stage = 10; running = true })
        })
        return
      } else if (stage >= 10 && stage < 13) {
        if (!peek.open) test.fail("q with unsaved changes should keep the peek open")
        if (stage++ < 12) return
        running = false
        test.ask(["--remote-send", ":w<CR>q"], () => { stage = 3; running = true })
        return
      } else if (stage === 3) {
        if (peek.open) { if (++waits < 10) return; test.fail("q in the peek should close it") }
        if (test.closes !== 1) test.fail("closing should be reported once, got " + test.closes)
        sample.reload()
        if (sample.text().split("\n")[41] !== "edited") test.fail(":w in the peek should save the edit, got " + sample.text().split("\n")[41])
        peek.show({ path: test.file, alternate: "" }, 3)
        running = false
        test.ask(["--remote-send", "q"], () => { stage++; running = true })
        return
      } else if (stage === 4) {
        if (peek.open) { if (++waits < 10) return; test.fail("q should close the peek a second time too") }
        console.log("PASS: the peek opens a file editable at its line in its own Neovim, :w saves, q closes it every time but not over unsaved changes")
        Qt.quit()
      }
      stage++
    }
  }
}

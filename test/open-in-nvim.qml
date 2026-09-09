import QtQuick
import Quickshell
import Quickshell.Io
import "."

ShellRoot {
  id: test
  property int phase: 0
  property int ticks: 0
  property string remoteRoot: "/home/david_karlsson_lovable_dev/src/lovable-every-7"
  AgentdState { id: state; configuredSockPaths: [Quickshell.env("XDG_RUNTIME_DIR") + "/open-agentd.sock"]; selectedSession: rail.selectedRaw; function send(message) { return true } }
  FloatingWindow {
    visible: true; width: 700; height: 650
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; nvimSock: "/tmp/open-test.sock" }
  }
  FileView { id: nvimCalls; path: Quickshell.env("HOME") + "/nvim-calls" }
  function receive(message) { state.onLine(JSON.stringify(message), 0) }
  function open(sid, path, line, column) {
    receive({ type: "tool_execution_start", session: sid, toolName: "open_in_nvim", toolCallId: sid + line,
      args: { path: path, line: line, column: column } })
  }
  Component.onCompleted: receive({ type: "roster", sessions: [
    { id: "local", name: "local", cwd: Quickshell.env("HOME") + "/repo", status: "idle" },
    { id: "remote", name: "remote", cwd: remoteRoot, status: "idle" }
  ] })
  Timer {
    interval: 100; repeat: true; running: true
    onTriggered: {
      nvimCalls.reload()
      var calls = nvimCalls.text().trim().split("\n").filter(function(x) { return x.length > 0 })
      if (++test.ticks > 50) throw new Error("open timeout: " + JSON.stringify({ phase: phase, calls: calls }))
      if (phase === 0) { rail.jumpToSession("local"); phase++ }
      else if (phase === 1 && rail.selectedRaw === "local") {
        if (rail._sessionCwdOf("local") !== Quickshell.env("HOME") + "/repo") throw new Error("local cwd missing: " + rail._sessionCwdOf("local"))
        open("local", "src/hash.ts", 42, 7); phase++
      }
      else if (phase === 2 && calls.length === 1) {
        if (calls[0].indexOf(Quickshell.env("HOME") + "/repo/src/hash.ts") < 0 || calls[0].indexOf("{42,6}") < 0)
          throw new Error("local file or cursor missing: " + calls[0])
        open("remote", "src/ignored.ts", 5, 1); phase++
      }
      else if (phase === 3) {
        if (calls.length !== 1) throw new Error("unselected session opened a file")
        rail.jumpToSession("remote"); phase++
      }
      else if (phase === 4 && rail.selectedRaw === "remote") { open("remote", remoteRoot + "/src/remote.ts", 9, 1); phase++ }
      else if (phase === 5 && calls.length === 2) {
        if (calls[1].indexOf(Quickshell.env("HOME") + "/work/lovable.daphen-every-7/src/remote.ts") < 0 || calls[1].indexOf("{9,0}") < 0)
          throw new Error("remote mirror or cursor missing: " + calls[1])
        console.log("PASS: agent tool opens local and mirrored files only for the selected session")
        Qt.quit()
      }
    }
  }
}

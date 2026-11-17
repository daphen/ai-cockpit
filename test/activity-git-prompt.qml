import QtQuick
import Quickshell
import Quickshell.Io
import QsLib
import "."

ShellRoot {
  id: test
  function check(ok, message) { if (!ok) { console.error("Error: " + message); Qt.exit(1) } }
  function event(message) { state.onLine(JSON.stringify(message), 0) }
  AgentdState { id: state; function send(message) { return true } }
  AgentdState { id: railState; function send(message) { return true } }
  FloatingWindow {
    visible: true; implicitWidth: 900; implicitHeight: 700
    Rail { id: rail; visible: false; width: 400; height: 400; agentd: railState; scopeMode: "personal"; instanceName: "activity-git-test" }
    ActivityStream { id: page; anchors.fill: parent; agentd: state; sessions: state.sessions; rail: rail }
  }
  readonly property string repo: Quickshell.env("XDG_RUNTIME_DIR") + "/git-prompt-repo"
  Process {
    running: true
    command: ["sh", "-c", 'rm -rf "$1" && mkdir -p "$1" && cd "$1" && git init -q && git config user.email t@t && git config user.name t'
      + ' && echo a > f.txt && git add . && git commit -qm "Shell fix"', "sh", test.repo]
  }
  property int n: 0
  property double rosterAt: 0
  // Activity keeps arriving the way the startup backfill delivers it.
  Timer {
    interval: 300; repeat: true; running: test.rosterAt > 0
    onTriggered: state._noteActivity([{ key: "prompt:a:" + (++test.n), sid: "a", at: Date.now(), kind: "prompt", from: "you", text: "ask " + test.n }])
  }
  Timer {
    interval: 100; repeat: true; running: true
    onTriggered: {
      if (!test.rosterAt) {
        if (Date.now() - startedAt < 800) return
        test.event({ type: "roster", sessions: [{ id: "a", name: "a", cwd: test.repo, status: "idle" }] })
        test.rosterAt = Date.now()
      } else if (Object.keys(page.repos).length) {
        var took = Date.now() - test.rosterAt
        test.check(took < 1500, "commits took " + took + "ms to load after the session appeared")
        console.log("PASS: commits load right away even while activity keeps arriving (" + took + "ms)")
        Qt.quit()
      } else test.check(Date.now() - test.rosterAt < 6000, "commits never loaded while activity kept arriving")
    }
    property double startedAt: Date.now()
  }
}

import QtQuick
import Quickshell

ShellRoot {
  property int stage: 0
  AgentdState {
    id: backend
    configuredSockPaths: [Quickshell.env("XDG_RUNTIME_DIR") + "/agentd-lovable.sock",
                          Quickshell.env("XDG_RUNTIME_DIR") + "/agentd-work.sock"]
  }
  Timer {
    interval: 25; repeat: true; running: true
    onTriggered: {
      if (stage === 0 && backend.sessions.length === 3) {
        backend.refreshChanges("remote-worker")
        stage = 1
      } else if (stage === 1 && backend.changesFor("remote-worker").length) {
        var file = backend.changesFor("remote-worker")[0]
        if (file.path !== "source.txt" || file.oldPath !== "old.txt" || !file.binary || file.add !== 7 || file.del !== 2)
          throw new Error("source routing or structured metadata was lost: " + JSON.stringify(file))
        if (backend.changeErrors["remote-worker"]) throw new Error("successful result remained unavailable")
        backend.refreshChanges("broken-worker")
        stage = 2
      } else if (stage === 2 && String(backend.changeErrors["broken-worker"]).indexOf("invalid Git HEAD") >= 0) {
        if (backend.changesFor("broken-worker").length) throw new Error("Git failure retained stale rows")
        console.log("PASS: source socket owns the diff; mirror ignored; errors stay visible")
        Qt.quit()
      }
    }
  }
}

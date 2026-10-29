import QtQuick
import Quickshell
import Quickshell.Io
import "."
ShellRoot {
  id: test
  property int phase: 0
  AgentdState { id: state; selectedSession: rail.selectedRaw; function send(message) { return true } }
  Process {
    running: true
    command: ["sh", "-c", 'd="$HOME/.config/niri/scripts"; mkdir -p "$d" "$HOME/My Files"; : > "$HOME/notes.md"; : > "$HOME/My Files/shot.png"; ' +
      'cp "$1" "$d/yazi-file-chooser"; chmod +x "$d/yazi-file-chooser"', "sh", Qt.resolvedUrl("fake-chooser.sh").toString().replace("file://", "")]
  }
  FloatingWindow { visible: true; width: 900; height: 1100
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "attach-test"; focused: false }
  }
  function find(item, name) {
    if (item.objectName === name) return item
    for (var child of item.children || []) { var match = find(child, name); if (match) return match }
    return null
  }
  function fail(message) { console.error("Error: " + message); Qt.quit() }
  Timer { interval: 250; repeat: true; running: true
    onTriggered: {
      if (test.phase === 0) {
        state.onLine(JSON.stringify({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle"}]}),0)
        rail.jumpToSession("worker")
      } else if (test.phase === 2) {
        var frame = test.find(rail, "composerFrame"), bar = test.find(rail, "composerToolbar"), attach = test.find(rail, "attachPill"), send = test.find(rail, "composerStatus")
        if (!frame || !bar || !attach || !send) { test.fail("composer toolbar missing"); return }
        var f = frame.mapToItem(rail, 0, 0), a = attach.mapToItem(rail, 0, 0), b = send.mapToItem(rail, 0, 0)
        if (a.y < f.y + frame.height / 2 || a.y + attach.height > f.y + frame.height + 2) { test.fail("attach is not in the input's bottom row"); return }
        if (a.x > f.x + 24) { test.fail("toolbar is not in the left corner: attach at x=" + (a.x - f.x)); return }
        if (b.x + send.width < f.x + frame.width - 16 || b.y + send.height > a.y) { test.fail("send button is not at the right of the input, above the toolbar"); return }
        state.sessions = [{ id: "worker", name: "worker", cwd: "/tmp", status: "streaming", scope: "personal" }]
        if (!send.working) { test.fail("send button did not become the orb while the agent works"); return }
        state.sessions = [{ id: "worker", name: "worker", cwd: "/tmp", status: "idle", scope: "personal" }]
        if (send.working) { test.fail("send button stayed an orb while the agent is idle"); return }
        rail.attachFiles()
      } else if (test.phase === 8) {
        var text = rail.composerField.text, home = Quickshell.env("HOME")
        var want = "@" + home + "/notes.md @" + JSON.stringify(home + "/My Files/shot.png") + " "
        if (text !== want) { test.fail("composer text was " + JSON.stringify(text)); return }
        console.log("PASS: attach/model/switch sit in the input's bottom-left, send bottom-right and turns into the orb only while working; attach inserts chosen files as @references")
        Qt.quit()
      }
      test.phase++
    }
  }
}

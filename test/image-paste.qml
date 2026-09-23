import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import "."
ShellRoot {
  id: test
  property int phase: 0
  property int ticks: 0
  property int target: 0
  property var sent: []
  property var names: ["orchestrator", "worker", "local", "lovbox"]
  property string vm: "/home/david_karlsson_lovable_dev/"
  SocketServer { active: true; path: Quickshell.env("XDG_RUNTIME_DIR") + "/agentd-work.sock"; handler: Socket {} }
  AgentdState {
    id: state
    configuredSockPaths: [Quickshell.env("XDG_RUNTIME_DIR") + "/agentd-work.sock"]
    selectedSession: rail.selectedRaw
    function send(message) { test.sent = test.sent.concat([message]); return true }
  }
  FloatingWindow {
    visible: true; implicitWidth: 720; implicitHeight: 800
    Rail {
      id: rail; anchors.fill: parent; agentd: state; scopeMode: "work"; focused: true; instanceName: "image-paste-test"
      onRequestFocus: forceActiveFocus()
      TestEvent { id: keys }
    }
  }
  FileView { id: transfers; path: Quickshell.env("HOME") + "/transfers"; printErrors: false }
  FileView { id: textMode; path: Quickshell.env("HOME") + "/text-mode"; blockWrites: true }
  Process {
    id: expire
    command: ["sh", "-c", 'touch -d "2 days ago" "$HOME"/.cache/heidr-pastes/* "$HOME"/.cache/heidr-pastes/.sequence; systemd-tmpfiles --user --clean "$HOME/expiry.conf"']
    onExited: (code, status) => { test.check(code === 0, "expiry failed"); test.phase = 1 }
  }
  function check(value, message) { if (!value) throw new Error(message) }
  function press(key, modifiers) { keys.keyClick(key, modifiers || Qt.NoModifier, 0) }
  Timer {
    interval: 100; repeat: true; running: true
    onTriggered: {
      if (++test.ticks > 70) throw new Error("paste timeout: " + test.names[test.target] + " phase=" + test.phase + " text=" + rail.composerText)
      if (test.phase === 0) {
        if (!state.connected) return
        state.onLine(JSON.stringify({type:"roster",sessions:[
          {id:"orchestrator",name:"orchestrator",cwd:test.vm+"src/lovable",status:"idle"},
          {id:"worker",name:"worker",cwd:test.vm+"src/lovable-every-1",status:"idle"},
          {id:"local",name:"local",cwd:Quickshell.env("HOME")+"/project",status:"idle"},
          {id:"lovbox",name:"lovbox",cwd:"/home/lovable/project",status:"idle"}
        ]}),0)
        test.phase++
      } else if (test.phase === 1) {
        rail.jumpToSession(test.names[test.target]); rail.prefillComposer(""); test.sent = []; test.phase++
      } else if (test.phase === 2) {
        test.press(Qt.Key_V, Qt.ControlModifier); test.phase++
      } else if (test.phase === 3 && /^\[img\d+\] $/.test(rail.composerText)) {
        transfers.reload()
        var uploads = transfers.text().trim().split("\n").filter(x => x.length)
        if (uploads.length < Math.min(test.target+1,2)) return
        test.check(uploads.length === Math.min(test.target+1,2), "local or lovbox paste used SSH")
        test.press(Qt.Key_Return); test.phase++
      } else if (test.phase === 4) {
        var prompt = test.sent.filter(m => m.type === "prompt").pop()
        test.check(prompt && prompt.session === test.names[test.target], "paste did not send to selected session: " + JSON.stringify(test.sent))
        var expected = test.target < 2 ? "@"+test.vm+".cache/heidr-pastes/img"+(test.target+3)+".png"
          : test.target === 2 ? "@"+Quickshell.env("HOME")+"/.cache/heidr-pastes/img5.png" : "@.heidr-pastes/img1.png"
        test.check(prompt.message.trim() === expected, "wrong image reference: " + prompt.message)
        test.target++; test.phase = test.target < test.names.length ? 1 : 5
        if (test.target === 1) { test.phase = 8; expire.running = true }
      } else if (test.phase === 5) {
        textMode.setText("text"); rail.prefillComposer("plain clipboard text"); test.press(Qt.Key_A,Qt.ControlModifier); test.press(Qt.Key_C,Qt.ControlModifier); test.press(Qt.Key_Backspace); test.phase++
      } else if (test.phase === 6) {
        test.press(Qt.Key_V,Qt.ControlModifier); test.phase++
      } else if (test.phase === 7 && rail.composerText === "plain clipboard text") {
        console.log("PASS: paste survives gaps and full cache expiry without number reuse; VM/local/lovbox references and text fallback work")
        Qt.quit()
      }
    }
  }
}

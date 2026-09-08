import QtQuick
import Quickshell
import Quickshell.Io
import "."
ShellRoot {
  id: test
  property int phase: 0
  property int ticks: 0
  property string vm: "/home/david_karlsson_lovable_dev/src/"
  AgentdState { id: state; selectedSession: rail.selectedRaw; function send(message) { return true } }
  FloatingWindow {
    visible: true; width: 700; height: 650
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "work"; instanceName: "mirror-test"; nvimSock: "/tmp/mirror-test.sock" }
  }
  FileView { id: calls; path: Quickshell.env("HOME") + "/mirror-calls" }
  FileView { id: done; path: Quickshell.env("HOME") + "/mirror-done" }
  FileView { id: nvimCalls; path: Quickshell.env("HOME") + "/nvim-calls" }
  function roster(status) {
    state.onLine(JSON.stringify({type:"roster",sessions:[
      {id:"every-1",name:"every-1",cwd:vm+"lovable-every-1",status:status},
      {id:"runtime-2",name:"runtime-2",cwd:vm+"lovable.alex-every-2-detail",status:"idle"},
      {id:"child-1",name:"child-1",cwd:vm+"lovable-every-1",parent:"every-1",status:"streaming"}
    ]}), 0)
  }
  Timer {
    interval: 100; repeat: true; running: true
    onTriggered: {
      calls.reload(); done.reload(); nvimCalls.reload()
      var lines = calls.text().trim().split("\n").filter(function(x) { return x.length > 0 })
      var refreshes = nvimCalls.text().split("\n").filter(function(line) { return line.indexOf("dashboard_snapshot") >= 0 })
      if (++test.ticks > 40) throw new Error("mirror timeout: " + JSON.stringify({phase:test.phase,calls:calls.text(),nvim:nvimCalls.text()}))
      if (test.phase === 0) { test.roster("streaming"); test.phase++ }
      else if (test.phase === 1) { rail.jumpToSession("every-1"); test.phase++ }
      else if (test.phase === 2 && refreshes.length === 1) { test.roster("idle"); test.phase++ }
      else if (test.phase === 3 && lines.length >= 2) {
        if (lines[1] !== "--prepare every-1") throw new Error("selected completion did not prepare while its child stayed busy")
        rail.jumpToSession("runtime-2"); test.phase++
      }
      else if (test.phase === 4 && done.text().indexOf("every-2") >= 0) test.phase++
      else if (test.phase === 5) test.phase++
      else if (test.phase === 6) { rail.jumpToSession("every-1"); test.phase++ }
      else if (test.phase === 7 && refreshes.length === 2) {
        if (lines.length !== 4) throw new Error("expected four preparations: " + JSON.stringify(lines))
        if (lines[0] !== "--prepare every-1" || lines[3] !== "--prepare every-1") throw new Error("canonical invocation mismatch")
        if (lines[2] !== "--prepare --remote-cwd " + test.vm + "lovable.alex-every-2-detail every-2") throw new Error("registered cwd was not preserved")
        console.log("PASS: mirror preparation follows selected completion, coalesces switches, preserves cwd, and ignores stale/failed results")
        Qt.quit()
      }
    }
  }
}

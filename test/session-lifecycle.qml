import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import "."
ShellRoot {
  id: test
  property int phase: 0
  property int ticks: 0
  property bool ready: false
  property bool dirtyReady: false
  readonly property string vm: "/home/david_karlsson_lovable_dev/src/"
  readonly property string mirror: Quickshell.env("HOME") + "/work/lovable.daphen-every-123"
  readonly property string socket: Quickshell.env("HOME") + "/nvim.sock"
  Process {
    running: true
    command: ["sh", "-c", 'mkdir -p "$HOME/.config/niri/scripts" "$HOME/work/lovable" "$HOME/work/lovable.daphen-every-123"; touch "$HOME/work/lovable.daphen-every-123/dirty.txt"; printf \'#!/bin/sh\necho "$*" >> "$HOME/calls"\necho "blocked dirty $2" >&2\nexit 7\n\' > "$HOME/.config/niri/scripts/vm-wt"; chmod +x "$HOME/.config/niri/scripts/vm-wt"; : > "$HOME/calls"']
    onExited: (code, status) => { if (code) throw new Error("setup failed"); test.ready = true }
  }
  Process { running: ready; command: ["nvim", "--headless", "--listen", socket, "-c", "cd " + mirror] }
  Process {
    id: dirtyEditor
    property string lua: '(function() local cwd=(vim.uv or vim.loop).cwd(); vim.cmd("edit "..vim.fn.fnameescape(' + JSON.stringify(mirror + "/dirty.txt") + ')); vim.api.nvim_buf_set_lines(0,0,-1,false,{"dirty"}); return cwd end)()'
    command: ["nvim", "--server", socket, "--remote-expr", "luaeval(" + JSON.stringify(lua) + ")"]
    stdout: StdioCollector { id: dirtyOutput }
    onExited: (code, status) => { if (code) throw new Error("editor setup failed"); test.dirtyReady = true }
  }
  AgentdState {
    id: state
    configuredSockPaths: [Quickshell.env("HOME") + "/missing.sock"]
    selectedSession: rail.selectedRaw
    function send(message) { return true }
  }
  FloatingWindow {
    visible: true
    implicitWidth: 720
    implicitHeight: 800
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "work"; focused: true; nvimSock: test.socket }
  }
  TestEvent { id: input }
  FileView { id: calls; path: Quickshell.env("HOME") + "/calls" }
  function check(ok, message) { if (!ok) throw new Error(message) }
  function textItem(item, text) {
    if (item.text === text) return item
    for (var child of item.children || []) { var found = textItem(child, text); if (found) return found }
    return null
  }
  function openActions() {
    for (var i = 0; i < rail.rosterList.length; i++) if (rail.rosterList[i].rawName === "ticket-worker") rail.cur = i
    rail.forceActiveFocus()
    input.keyClick(Qt.Key_X, Qt.NoModifier, 0)
  }
  function clickChoice(text) {
    var item = textItem(rail, text)
    check(item, "missing choice: " + text)
    input.mouseClick(item, 10, item.height / 2, Qt.LeftButton, Qt.NoModifier, 0)
  }
  Timer {
    interval: 150
    repeat: true
    running: true
    onTriggered: {
      if (++ticks > 70) throw new Error("timeout at " + phase)
      if (!ready || ticks < 5) return
      if (phase === 0) {
        state.onLine(JSON.stringify({type:"roster",sessions:[{id:"main",name:"main",cwd:"/tmp/main",status:"idle"},{id:"worker",name:"ticket-worker",profile:"lovable-worker",cwd:vm+"lovable-every-123",status:"idle"},{id:"local",name:"local",cwd:"/tmp/local",status:"idle"},{id:"orch",name:"orch",profile:"lovable-orchestrator",cwd:vm+"lovable-every-999",status:"idle"}]}), 0)
        rail.jumpToSession("main")
        check(!rail._ticketLifecycle("local") && !rail._ticketLifecycle("orch"), "protected context became eligible")
        openActions(); phase++
      } else if (phase === 1) {
        check(textItem(rail, "Turn off — keep files"), "Turn off choice missing")
        clickChoice("REAP — remove worktree and exclusive caches"); phase++
      } else if (phase === 2) {
        clickChoice("CONFIRM REAP EVERY-123 — remove worktree and exclusive caches"); phase++
      } else if (phase === 3 && rail.lifecycleMessage.indexOf("exit 7") >= 0) {
        calls.reload(); dirtyEditor.running = true; phase++
      } else if (phase === 4 && dirtyReady) {
        check(dirtyOutput.text.trim() === Quickshell.env("HOME") + "/work/lovable", "cwd was not released")
        check(calls.text().trim() === "--reap EVERY-123", "wrong canonical command")
        check(state.sessions.some(function(s) { return s.name === "ticket-worker" }), "row removed early")
        openActions(); phase++
      } else if (phase === 5) {
        clickChoice("REAP — remove worktree and exclusive caches"); phase++
      } else if (phase === 6) {
        clickChoice("CONFIRM REAP EVERY-123 — remove worktree and exclusive caches"); phase++
      } else if (phase === 7 && rail.lifecycleMessage.indexOf("BLOCK modified file:") >= 0) {
        calls.reload(); phase++
      } else if (phase === 8) {
        check(calls.text().trim().split("\n").length === 1, "blocked REAP reached launcher")
        check(state.sessions.some(function(s) { return s.name === "ticket-worker" }), "blocked row disappeared")
        console.log("PASS: lifecycle picker, canonical REAP result, cwd release, and modified-buffer block")
        Qt.quit()
      }
    }
  }
}

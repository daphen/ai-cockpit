import QtQuick
import Quickshell
import Quickshell.Io
import "."

ShellRoot {
  id: test
  property var seen: []
  property var commands: []
  property var historyRequests: []
  property bool online: true
  AgentdState {
    id: backend
    configuredSockPaths: [Quickshell.env("XDG_RUNTIME_DIR") + "/agentd-work.sock"]
    selectedSession: "ticket-a"
    function send(message) {
      if (!test.online) return false
      if (message.type === "get_entries") test.historyRequests.push(message.session)
      else test.commands.push(message)
      return true
    }
    onEditSeen: (sid, path, needle, historical) => test.seen.push({ sid: sid, path: path, historical: historical })
  }
  Component { id: landingRail; Rail { agentd: backend; scopeMode: "work"; nvimSock: "/tmp/landing-test.sock" } }
  FileView { id: nvimCalls; path: Quickshell.env("HOME") + "/nvim-calls" }
  Timer {
    interval: 30; repeat: true; running: true
    onTriggered: {
      nvimCalls.reload()
      var calls = nvimCalls.text()
      if (!calls.length) return
      check(calls.indexOf(',"work","/home/david_karlsson_lovable_dev/src/lovable-every-1")') >= 0,
            "workspace handoff lost VM scope/directory: " + calls)
      console.log("PASS: history, interruption, streaming, and source-scoped editor handoff")
      Qt.quit()
    }
  }
  function check(ok, message) { if (!ok) throw new Error(message) }
  function receive(message) { backend.onLine(JSON.stringify(message), 0) }
  function history(sid, paths) {
    receive({ type: "response", command: "get_entries", session: sid,
      data: { entries: [{ id: "m1", type: "message", message: { role: "assistant",
        content: paths.map(function(path, i) {
          return { type: "toolCall", id: "edit" + i, name: "edit", arguments: { path: path, edits: [] } }
        }) } }] } })
  }
  Component.onCompleted: {
    receive({ type: "roster", sessions: [{ id: "ticket-a", name: "ticket-a", status: "idle", cwd: "/tmp/ticket-a" }] })
    check(historyRequests.length === 1 && historyRequests[0] === "ticket-a", "first roster hydrates an already-selected empty feed")
    historyRequests = []
    history("ticket-a", ["src/old.ts", "src/latest.ts", ".plans/TICKET-A.md", ".plans/TICKET-A.progress.json"])
    check(backend.lastEditFor("ticket-a") === "src/latest.ts", "history must skip plan bookkeeping")
    check(seen.length === 1 && seen[0].historical && seen[0].sid === "ticket-a", "late history must notify editor")
    history("ticket-b", ["src/other.ts"])
    check(seen.length === 1 && backend.lastEditFor("ticket-a") === "src/latest.ts", "unselected history is ignored")
    history("ticket-a", [])
    check(backend.lastEditFor("ticket-a") === "", "empty history clears stale last edit")
    receive({ type: "tool_execution_start", session: "ticket-a", toolName: "edit", toolCallId: "live",
      args: { path: "src/live.ts", edits: [] } })
    check(seen.length === 2 && !seen[1].historical && seen[1].path === "src/live.ts", "live edits still notify")
    receive({ type: "tool_execution_start", session: "ticket-a", toolName: "write", toolCallId: "plan",
      args: { path: "/home/test/personal/notes/storage/plans/TICKET-A.md", content: "plan" } })
    check(seen.length === 2 && backend.lastEditFor("ticket-a") === "src/live.ts", "live plan edits must not replace code landing")
    backend.interrupt("ticket-a")
    check(commands.length === 1 && commands[0].type === "abort", "interrupt reaches transport")
    check(!backend.feedFor("ticket-a").some(function(item) { return String(item.text).indexOf("turn aborted") >= 0 }), "socket write is not confirmation")
    backend.submit("ticket-a", "after interrupt")
    backend.enqueue("ticket-a", "next message")
    check(commands.length === 1 && backend.queuedFor("ticket-a") === 2, "messages wait instead of steering while stopping")
    receive({ type: "turn_end", session: "ticket-a" })
    check(backend.isInterrupting("ticket-a"), "intermediate turn end does not confirm abort")
    receive({ type: "response", command: "abort", success: true, session: "ticket-a" })
    check(commands.length === 2 && commands[1].type === "prompt" && commands[1].message === "after interrupt", "confirmed abort releases fresh prompt: " + JSON.stringify(commands))
    receive({ type: "response", command: "abort", success: true, session: "ticket-a" })
    check(commands.length === 2 && backend.queuedFor("ticket-a") === 1, "duplicate response does not release another message")
    receive({ type: "agent_end", session: "ticket-a" })
    check(commands.length === 3 && commands[2].type === "prompt" && commands[2].message === "next message", "remaining queue waits for next completion")
    receive({ type: "agent_end", session: "ticket-a" })
    online = false
    backend.interrupt("ticket-a")
    check(!backend.isInterrupting("ticket-a") && backend.feedFor("ticket-a").some(function(item) { return String(item.text).indexOf("interrupt not delivered") >= 0 }), "offline interrupt visibly fails")
    online = true
    historyRequests = []
    history("ticket-a", [])
    receive({ type: "message_start", session: "ticket-a", message: { role: "assistant" } })
    receive({ type: "message_update", session: "ticket-a", assistantMessageEvent: { type: "text_start", contentIndex: 0 } })
    receive({ type: "message_update", session: "ticket-a", assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "First words" } })
    check(backend.feedFor("ticket-a").some(function(item) { return item.text === "First words" }), "text appears before message completion")
    history("ticket-a", [])
    check(backend.feedFor("ticket-a").some(function(item) { return item.text === "First words" }), "initial history does not erase arriving live text")
    receive({ type: "message_update", session: "ticket-a", assistantMessageEvent: { type: "text_start", contentIndex: 1 } })
    receive({ type: "message_update", session: "ticket-a", assistantMessageEvent: { type: "text_delta", contentIndex: 1, delta: "Second paragraph" } })
    receive({ type: "message_end", session: "ticket-a", message: { role: "assistant", content: [{ type: "text", text: "First words" }, { type: "text", text: "Second paragraph" }] } })
    check(backend.feedFor("ticket-a").filter(function(item) { return item.text === "First words\n\nSecond paragraph" }).length === 1, "completion updates live prose without duplicating it")
    receive({ type: "turn_end", session: "ticket-a" })
    check(historyRequests.length === 0, "tool rounds never request full history")
    receive({ type: "agent_end", session: "ticket-a" })
    check(historyRequests.length === 1 && historyRequests[0] === "ticket-a", "whole-turn completion requests selected history once")
    backend.selectedSession = ""
    receive({ type: "turn_end", session: "ticket-a" })
    receive({ type: "agent_end", session: "ticket-a" })
    check(historyRequests.length === 1, "inactive scope never refreshes cached history")
    var before = backend.feedFor("ticket-a").length
    history("ticket-a", ["another.ts"])
    receive({ type: "message_update", session: "ticket-a", assistantMessageEvent: { type: "text_delta", delta: "hidden" } })
    check(backend.feedFor("ticket-a").length === before, "inactive replies do not churn the feed")
    var rail = landingRail.createObject(test)
    receive({ type: "roster", sessions: [{ name: "vm", id: "vm", status: "idle",
      cwd: "/home/david_karlsson_lovable_dev/src/lovable-every-1" }] })
    rail.landNvim("vm", "diff")
  }
}

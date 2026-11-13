import QtQuick
import QtTest
import Quickshell
import QsLib
import "."

ShellRoot {
  id: test
  property var sent: []
  property var opened: []
  function fail(message) { console.error("Error: " + message); Qt.quit() }
  function event(message) { state.onLine(JSON.stringify(message), 0) }
  function find(item, pred) {
    if (pred(item)) return item
    for (var child of item.children || []) { var hit = find(child, pred); if (hit) return hit }
    if (item.contentItem && item.contentItem !== item) return find(item.contentItem, pred)
    return null
  }
  function hasText(part) { return !!find(page, item => item.visible && String(item.text || "").indexOf(part) >= 0) }
  function visibleText(text) { return !!find(page, item => item.visible && String(item.text || "") === text) }
  AgentdState { id: state; function send(message) { test.sent.push(message); return true } }
  FloatingWindow {
    visible: true; implicitWidth: 1100; implicitHeight: 900
    TestEvent { id: input }
    ActivityStream {
      id: page
      anchors.fill: parent
      visible: false
      agentd: state
      sessions: state.sessions
      onSessionRequested: sid => test.opened.push(sid)
      onFileRequested: (sid, path, line) => test.opened.push(sid + ":" + path + ":" + line)
    }
  }
  function key(k, mods) { input.keyClick(k, mods || Qt.NoModifier, 0) }
  readonly property double t0: Date.parse("2026-11-12T09:00:00Z")
  Timer {
    property int stage: 0
    interval: 400; repeat: true; running: true
    onTriggered: {
      if (stage === 0) {
        test.event({ type: "roster", sessions: [{ id: "alpha", name: "alpha", cwd: "/r", status: "idle" },
                                               { id: "beta", name: "beta", cwd: "/tmp/b", status: "streaming" }] })
        if (test.sent.some(m => m.type === "get_entries")) test.fail("history loaded before the page was shown")
        page.visible = true
      } else if (stage === 2) {
        var asked = test.sent.filter(m => m.type === "get_entries").map(m => m.session).sort().join(",")
        if (asked !== "alpha,beta") test.fail("history was requested for " + asked)
        test.event({ type: "response", command: "get_entries", session: "alpha", success: true, data: { entries: [
          { type: "message", id: "u1", timestamp: new Date(test.t0).toISOString(), message: { role: "user", timestamp: test.t0,
            content: [{ type: "text", text: "\u21c4 nixos (user-approved)\nBuild the activity view" }] } },
          { type: "custom", id: "t1", customType: "cockpit-session-task", timestamp: new Date(test.t0 + 1000).toISOString(), data: { action: "switch", title: "Activity view" } },
          { type: "message", id: "a1", message: { role: "assistant", timestamp: test.t0 + 2000, content: [
            { type: "text", text: "Looking around.\n\nThe rail needs a hook so the page can open files." },
            { type: "toolCall", id: "e1", name: "edit", arguments: { path: "/r/Rail.qml", edits: [] } },
            { type: "toolCall", id: "e2", name: "write", arguments: { path: "/r/New.qml", content: "a\nb" } }] } },
          { type: "message", id: "r1", message: { role: "toolResult", toolCallId: "e1", timestamp: test.t0 + 3000, details: { diff: "  9 ctx\n+10 x\n+11 y\n-12 z", firstChangedLine: 10 } } },
          { type: "message", id: "r2", message: { role: "toolResult", toolCallId: "e2", timestamp: test.t0 + 4000 } },
          { type: "message", id: "a2", message: { role: "assistant", timestamp: test.t0 + 5000, content: [{ type: "text", text: "Done.\n\u27e2 Activity view renders history." }] } }
        ] } })
        // The same transcript again must not duplicate rows.
        test.event({ type: "response", command: "get_entries", session: "alpha", success: true, data: { entries: [
          { type: "message", id: "a2", message: { role: "assistant", timestamp: test.t0 + 5000, content: [{ type: "text", text: "\u27e2 Activity view renders history." }] } }] } })
      } else if (stage === 3) {
        var kinds = state.activity.map(r => r.kind).sort().join(",")
        if (kinds !== "edit,edit,prompt,summary,task") test.fail("history rows were " + kinds)
        var prompt = state.activity.find(r => r.kind === "prompt")
        if (prompt.from !== "nixos" || prompt.text !== "Build the activity view") test.fail("relayed prompt lost its sender: " + JSON.stringify(prompt))
        if (!test.visibleText("\u27e2 Activity view renders history.")) test.fail("task result not shown")
        if (!test.visibleText("nixos: Build the activity view")) test.fail("the prompt behind the task is not shown with its sender")
        if (!test.visibleText("The rail needs a hook so the page can open files.")) test.fail("the agent's reason for the edit is not shown")
        if (!test.visibleText("Activity view")) test.fail("task title not shown")
        if (!test.hasText("Rail.qml") || !test.hasText("New.qml")) test.fail("changed files not shown")
        if (!test.visibleText("+2") || !test.visibleText("-1")) test.fail("per-file counts wrong")
        if (!test.visibleText("+ x") || test.hasText("ctx")) test.fail("diff preview should show only the changed lines")
        state.sendPrompt("beta", "keep going")
        test.event({ type: "message_end", session: "beta", message: { role: "assistant", timestamp: Date.now(), content: [
          { type: "text", text: "Live needs its own file so the stream can follow it." }, { type: "toolCall", id: "live1", name: "edit", arguments: { path: "/r/Live.qml" } }] } })
        test.event({ type: "tool_execution_start", session: "beta", toolName: "edit", toolCallId: "live1", args: { path: "/r/Live.qml", edits: [] } })
        test.event({ type: "tool_execution_end", session: "beta", toolName: "edit", toolCallId: "live1", result: { details: { diff: "+ 1 a" } } })
        test.event({ type: "message_end", session: "beta", message: { role: "assistant", timestamp: Date.now(), content: [{ type: "text", text: "\u27e2 Beta shipped." }] } })
      } else if (stage === 4) {
        if (!test.visibleText("\u27e2 Beta shipped.")) test.fail("live result not shown")
        if (!test.hasText("Live.qml")) test.fail("live edit not shown")
        if (!test.visibleText("Live needs its own file so the stream can follow it.")) test.fail("live edit lost its reason")
        if (!test.find(page, item => item.visible && /^beta  /.test(String(item.text || "")))) test.fail("working session missing from the now strip")
        page.forceActiveFocus()
        test.key(Qt.Key_Return)
        if (String(test.opened) !== "beta:/r/Live.qml:1") test.fail("Enter on the newest change opened " + test.opened)
        var before = page.restPoint
        if (!before) test.fail("no cursor dot on the focused page")
        test.key(Qt.Key_K); test.key(Qt.Key_K)
        if (!page.restPoint || page.restPoint.y >= before.y) test.fail("cursor dot did not move up with k")
        test.key(Qt.Key_Return)
        if (test.opened[1] !== "alpha:/r/Rail.qml:10") test.fail("moving up then opening went to " + test.opened)
        test.key(Qt.Key_S)
        if (test.opened[2] !== "alpha") test.fail("s did not open the change's session: " + test.opened)
        console.log("PASS: activity page backfills transcripts once, shows only code changes grouped by session task with the prompt behind it, each change with the reason the agent gave, per-file counts, changed-line previews and the task result, follows live edits, and Enter opens the changed file at its line in that session")
        Qt.quit()
      }
      stage++
    }
  }
}

import QtQuick
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
  function visibleText(text) { return !!find(dash, item => item.visible && String(item.text || "") === text) }
  AgentdState { id: state; function send(message) { test.sent.push(message); return true } }
  FloatingWindow {
    visible: true; implicitWidth: 1100; implicitHeight: 900
    Dashboard {
      id: dash
      anchors.fill: parent
      agentd: state
      sessions: state.sessions
      model: ({ kind: "home", scope: "personal", cards: [{ title: "PLANS", rows: [{ text: "A plan", action: "plan:p" }] }] })
      onSessionRequested: sid => test.opened.push(sid)
    }
  }
  readonly property double t0: Date.parse("2026-11-12T09:00:00Z")
  Timer {
    property int stage: 0
    interval: 400; repeat: true; running: true
    onTriggered: {
      if (stage === 0) {
        test.event({ type: "roster", sessions: [{ id: "alpha", name: "alpha", cwd: "/tmp/a", status: "idle" },
                                               { id: "beta", name: "beta", cwd: "/tmp/b", status: "streaming" }] })
        if (String(dash.tabs) !== "sessions,plans,activity") test.fail("tabs were " + dash.tabs)
        dash.dispatch("tab"); dash.dispatch("tab")
        if (!dash.showActivity || dash.showSessions || dash.activeTab !== "activity") test.fail("Tab did not reach the activity page")
        if (test.visibleText("A plan")) test.fail("activity page still shows the plan cards")
      } else if (stage === 2) {
        var asked = test.sent.filter(m => m.type === "get_entries").map(m => m.session).sort().join(",")
        if (asked !== "alpha,beta") test.fail("history was requested for " + asked)
        test.event({ type: "response", command: "get_entries", session: "alpha", success: true, data: { entries: [
          { type: "message", id: "u1", timestamp: new Date(test.t0).toISOString(), message: { role: "user", timestamp: test.t0,
            content: [{ type: "text", text: "\u21c4 nixos (user-approved)\nBuild the activity view" }] } },
          { type: "custom", id: "t1", customType: "cockpit-session-task", timestamp: new Date(test.t0 + 1000).toISOString(), data: { action: "switch", title: "Activity view" } },
          { type: "message", id: "a1", message: { role: "assistant", timestamp: test.t0 + 2000, content: [
            { type: "toolCall", id: "e1", name: "edit", arguments: { path: "/r/Rail.qml", edits: [] } },
            { type: "toolCall", id: "e2", name: "write", arguments: { path: "/r/New.qml", content: "a\nb" } }] } },
          { type: "message", id: "r1", message: { role: "toolResult", toolCallId: "e1", timestamp: test.t0 + 3000, details: { diff: "+ 1 x\n+ 2 y\n- 3 z" } } },
          { type: "message", id: "r2", message: { role: "toolResult", toolCallId: "e2", timestamp: test.t0 + 4000 } },
          { type: "message", id: "a2", message: { role: "assistant", timestamp: test.t0 + 5000, content: [{ type: "text", text: "Done.\n\u27e2 Activity view renders history." }] } }
        ] } })
        // The same transcript again must not duplicate rows.
        test.event({ type: "response", command: "get_entries", session: "alpha", success: true, data: { entries: [
          { type: "message", id: "a2", message: { role: "assistant", timestamp: test.t0 + 5000, content: [{ type: "text", text: "\u27e2 Activity view renders history." }] } }] } })
      } else if (stage === 3) {
        var kinds = dash.agentd.activity.map(r => r.kind).sort().join(",")
        if (kinds !== "edit,edit,prompt,summary,task") test.fail("history rows were " + kinds)
        var prompt = state.activity.find(r => r.kind === "prompt")
        if (prompt.from !== "nixos" || prompt.text !== "Build the activity view") test.fail("relayed prompt lost its sender: " + JSON.stringify(prompt))
        if (!test.visibleText("\u27e2 Activity view renders history.")) test.fail("summary not shown")
        if (!test.visibleText("Build the activity view") || !test.visibleText("From nixos")) test.fail("prompt and its sender not shown")
        if (!test.visibleText("Activity view")) test.fail("task title not shown")
        if (!test.visibleText("Rail.qml, New.qml")) test.fail("edits in one turn did not fold into one line")
        if (!test.visibleText("+4") || !test.visibleText("-1")) test.fail("folded edit counts wrong")
        state.sendPrompt("beta", "keep going")
        test.event({ type: "tool_execution_start", session: "beta", toolName: "edit", toolCallId: "live1", args: { path: "/r/Live.qml", edits: [] } })
        test.event({ type: "tool_execution_end", session: "beta", toolName: "edit", toolCallId: "live1", result: { details: { diff: "+ 1 a" } } })
        test.event({ type: "message_end", session: "beta", message: { role: "assistant", timestamp: Date.now(), content: [{ type: "text", text: "\u27e2 Beta shipped." }] } })
      } else if (stage === 4) {
        if (!test.visibleText("\u27e2 Beta shipped.")) test.fail("live summary not shown")
        if (!test.visibleText("Live.qml")) test.fail("live edit not shown")
        if (!test.find(dash, item => item.visible && /^beta  /.test(String(item.text || "")))) test.fail("working session missing from the now strip")
        dash.forceActiveFocus()
        dash.activate(false)
        if (String(test.opened) !== "beta") test.fail("Enter on the newest row opened " + test.opened)
        dash.move(1); dash.move(1)
        dash.activate(true)
        if (String(test.opened) !== "beta,alpha") test.fail("moving down then opening went to " + test.opened)
        console.log("PASS: activity page replaces the cards, backfills every session's transcript once without duplicates, groups each turn as asked, task, result and files, appends live events, and Enter opens the row's session")
        Qt.quit()
      }
      stage++
    }
  }
}

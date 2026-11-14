import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import QsLib
import "."

ShellRoot {
  id: test
  property var sent: []
  property var opened: []
  property var codeFlick: null
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
  AgentdState { id: railState; function send(message) { return true } }
  FloatingWindow {
    visible: true; implicitWidth: 1100; implicitHeight: 900
    TestEvent { id: input }
    Rail { id: rail; visible: false; width: 400; height: 400; agentd: railState; scopeMode: "personal"; instanceName: "activity-stream-test" }
    ActivityStream {
      id: page
      anchors.fill: parent
      visible: false
      agentd: state
      sessions: state.sessions
      rail: rail
      onSessionRequested: sid => test.opened.push(sid)
      onFileRequested: (sid, path, line) => test.opened.push(sid + ":" + path + ":" + line)
    }
  }
  function key(k, mods) { input.keyClick(k, mods || Qt.NoModifier, 0) }
  readonly property double t0: Math.floor(Date.now() / 1000) * 1000 - 2 * 3600000
  readonly property string repo: Quickshell.env("XDG_RUNTIME_DIR") + "/repo"
  Process {
    running: true
    command: ["sh", "-c", 'mkdir -p "$1" && cd "$1" && git init -q && git config user.email t@t && git config user.name t'
      + ' && printf "a\\nb\\nc\\n" > f.txt && git add . && GIT_AUTHOR_DATE=@$2 GIT_COMMITTER_DATE=@$2 git commit -qm init'
      + ' && printf "a\\nB\\nc\\n" > f.txt && printf "G\\n" > g.txt && git add g.txt && GIT_AUTHOR_DATE=@$3 GIT_COMMITTER_DATE=@$3 git commit -qam "Fix via shell"',
      "sh", test.repo, String(test.t0 / 1000 - 3600), String(test.t0 / 1000 + 10)]
  }
  Timer {
    property int stage: 0
    property int waits: 0
    interval: 400; repeat: true; running: true
    onTriggered: {
      if (stage === 0) {
        test.event({ type: "roster", sessions: [{ id: "alpha", name: "alpha", cwd: "/r", status: "idle" },
                                               { id: "beta", name: "beta", cwd: "/tmp/b", status: "streaming" }] })
        if (test.sent.some(m => m.type === "get_entries")) test.fail("history loaded before the page was shown")
        page.visible = true
      } else if (stage === 1) {
        test.event({ type: "roster", sessions: [{ id: "alpha", name: "alpha", cwd: "/r", status: "idle" },
                                               { id: "beta", name: "beta", cwd: "/tmp/b", status: "streaming" },
                                               { id: "gamma", name: "gamma", cwd: test.repo, status: "idle" }] })
      } else if (stage === 2) {
        test.event({ type: "response", command: "get_entries", session: "alpha", success: true, data: { entries: [
          { type: "message", id: "a0", message: { role: "assistant", timestamp: test.t0 - 5 * 3600000, content: [
            { type: "toolCall", id: "e0", name: "edit", arguments: { path: "/r/Old.qml", edits: [] } }] } },
          { type: "message", id: "r0", message: { role: "toolResult", toolCallId: "e0", timestamp: test.t0 - 5 * 3600000, details: { diff: "+ 1 old" } } },
          { type: "message", id: "u1", timestamp: new Date(test.t0).toISOString(), message: { role: "user", timestamp: test.t0,
            content: [{ type: "text", text: "\u21c4 nixos (user-approved)\nBuild the activity view" }] } },
          { type: "custom", id: "t1", customType: "cockpit-session-task", timestamp: new Date(test.t0 + 1000).toISOString(), data: { action: "switch", title: "Activity view" } },
          { type: "message", id: "a1", message: { role: "assistant", timestamp: test.t0 + 2000, content: [
            { type: "text", text: "Looking around.\n\nThe rail needs a hook so the page can open files." },
            { type: "toolCall", id: "e1", name: "edit", arguments: { path: "/r/Rail.qml", edits: [] } },
            { type: "toolCall", id: "e2", name: "write", arguments: { path: "/r/New.qml", content: "a\nb" } }] } },
          { type: "message", id: "r1", message: { role: "toolResult", toolCallId: "e1", timestamp: test.t0 + 3000, details: { diff: "  9 ctx\n+10 x = 1 // set\n+11 property string y: Text.Wrap\n-12 z", firstChangedLine: 10 } } },
          { type: "message", id: "r2", message: { role: "toolResult", toolCallId: "e2", timestamp: test.t0 + 4000 } },
          { type: "message", id: "a2", message: { role: "assistant", timestamp: test.t0 + 5000, content: [{ type: "text", text: "Done.\n\u27e2 Activity view renders history." }] } }
        ] } })
        test.event({ type: "response", command: "get_entries", session: "gamma", success: true, data: { entries: [
          { type: "message", id: "g1", timestamp: new Date(test.t0 - 60000).toISOString(), message: { role: "user", timestamp: test.t0 - 60000,
            content: [{ type: "text", text: "Fix the shell script" }] } }] } })
        // The same transcript again must not duplicate rows.
        test.event({ type: "response", command: "get_entries", session: "alpha", success: true, data: { entries: [
          { type: "message", id: "a2", message: { role: "assistant", timestamp: test.t0 + 5000, content: [{ type: "text", text: "\u27e2 Activity view renders history." }] } }] } })
      } else if (stage === 3) {
        if (!test.visibleText("Committed: Fix via shell") && waits++ < 20) return
        var asked = test.sent.filter(m => m.type === "get_entries").map(m => m.session).sort().join(",")
        if (asked !== "alpha,beta,gamma") test.fail("history was requested for " + asked)
        var kinds = state.activity.map(r => r.kind).sort().join(",")
        if (kinds !== "edit,edit,edit,prompt,prompt,summary,task") test.fail("history rows were " + kinds)
        var prompt = state.activity.find(r => r.kind === "prompt")
        if (prompt.from !== "nixos" || prompt.text !== "Build the activity view") test.fail("relayed prompt lost its sender: " + JSON.stringify(prompt))
        if (test.hasText("Activity view renders history.")) test.fail("outcomes are not changes and should not be listed")
        if (test.find(page, item => item.visible && String(item.text || "") === "Activity view") === null) test.fail("the task behind the changes is not shown")
        var asks = []
        test.find(page, item => { if (item.visible && item.text === "Activity view") asks.push(item); return false })
        if (new Set(asks).size !== 1) test.fail("the ask should appear once above consecutive changes, got " + new Set(asks).size)
        if (!test.visibleText("The rail needs a hook so the page can open files.")) test.fail("the agent's reason for the edit is not shown")
        if (!test.hasText("Rail.qml") || !test.hasText("New.qml")) test.fail("changed files not shown")
        if (!test.visibleText("Wrote the whole file \u00b7 Enter opens it")) test.fail("a written file should be summarised, not dumped")
        if (!test.visibleText("+2") || !test.visibleText("-1")) test.fail("per-change counts wrong")
        if (!test.hasText("&nbsp;&nbsp;</font>x") || !test.hasText("&nbsp;&nbsp;</font>ctx")) test.fail("diff preview should show the change with its context")
        if (!test.hasText('</font>x&nbsp;<font color="' + Theme.syntaxOperator + '">=</font>&nbsp;<font color="' + Theme.syntaxNumber + '">1</font>&nbsp;<i><font color="' + Theme.syntaxComment + '">//&nbsp;set</font></i>'))
          test.fail("diff code is not in the Neovim theme's operator/number/comment colors")
        if (!test.hasText('<font color="' + Theme.syntaxType + '">string</font>&nbsp;y:&nbsp;<font color="' + Theme.syntaxType + '">Text</font>.Wrap'))
          test.fail("QML types are not in the Neovim theme's type color")
        if (!test.hasText('&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</font><font color="' + Theme.red + '">z</font>'))
          test.fail("a removed line should read like hunk-nvim's ghost line: red, unhighlighted, unnumbered")
        if (!test.visibleText("Committed: Fix via shell")) test.fail("a commit made outside the edit tool is missing")
        if (test.visibleText("Committed: init")) test.fail("a commit no session was active before belongs to nobody, not to whichever session sits in that repo")
        if (!test.hasText("&nbsp;&nbsp;</font>B")) test.fail("the commit's changed line is not shown")
        var at = pred => { var it = test.find(page, i => i.visible && pred(String(i.text || ""))); return it ? it.mapToItem(page, 0, 0).y : NaN }
        var fy = at(t => t.endsWith("</font>f.txt")), by = at(t => t.endsWith("</font>B")), gy = at(t => t.endsWith("</font>g.txt")), Gy = at(t => t.endsWith("</font>G"))
        if (!(fy < by && by < gy && gy < Gy)) test.fail("each file of a commit should sit directly above its own diff: " + [fy, by, gy, Gy])
        state.sendPrompt("beta", "keep going")
        test.event({ type: "message_end", session: "beta", message: { role: "assistant", timestamp: Date.now(), content: [
          { type: "text", text: "Live needs its own file so the stream can follow it." }, { type: "toolCall", id: "live1", name: "edit", arguments: { path: "/r/Live.qml" } }] } })
        test.event({ type: "tool_execution_start", session: "beta", toolName: "edit", toolCallId: "live1", args: { path: "/r/Live.qml", edits: [] } })
        test.event({ type: "tool_execution_end", session: "beta", toolName: "edit", toolCallId: "live1", result: { details: { diff: "+ 1 a" + "_".repeat(400) } } })
        test.event({ type: "message_end", session: "beta", message: { role: "assistant", timestamp: Date.now(), content: [{ type: "text", text: "\u27e2 Beta shipped." }] } })
      } else if (stage === 4) {
        if (!test.hasText("Live.qml")) test.fail("live edit not shown")
        if (!test.visibleText("Live needs its own file so the stream can follow it.")) test.fail("live edit lost its reason")
        if (test.hasText("streaming") || test.hasText("thinking") || test.hasText("working")) test.fail("live status does not belong on the activity page")
        page.forceActiveFocus()
        test.key(Qt.Key_Return)
        if (String(test.opened) !== "beta:/r/Live.qml:1") test.fail("Enter on the newest change opened " + test.opened)
        var before = page.restPoint
        if (!before) test.fail("no cursor dot on the focused page")
        test.key(Qt.Key_K); test.key(Qt.Key_K)
        if (!page.restPoint || page.restPoint.y >= before.y) test.fail("cursor dot did not move up with k")
        test.key(Qt.Key_Return)
        if (test.opened[1] !== "alpha:/r/New.qml:1") test.fail("moving up past the commit then opening went to " + test.opened)
        test.key(Qt.Key_K); test.key(Qt.Key_Return)
        if (test.opened[2] !== "alpha:/r/Rail.qml:10") test.fail("opening an edit went to " + test.opened)
        test.key(Qt.Key_J); test.key(Qt.Key_J)
        if (page.currentRow.why !== "Fix via shell" || page.currentRow.files.length !== 2) test.fail("expected the two-file commit, got " + page.currentRow.why)
        test.key(Qt.Key_Return)
        if (test.opened.length !== 3 || page.itemIndex !== 0) test.fail("Enter on a change with several files should step inside it, not open one")
        test.key(Qt.Key_Return)
        if (test.opened[3] !== "gamma:" + test.repo + "/f.txt:2") test.fail("Enter inside a commit should open its first file: " + test.opened)
        test.key(Qt.Key_J); test.key(Qt.Key_Return)
        if (test.opened[4] !== "gamma:" + test.repo + "/g.txt:1") test.fail("j then Enter inside a change should open the second file, got " + test.opened)
        test.key(Qt.Key_Escape)
        if (page.itemIndex !== -1) test.fail("Esc should leave the change")
        test.opened.pop()
        test.key(Qt.Key_S)
        if (test.opened[4] !== "gamma") test.fail("s did not open the change's session: " + test.opened)
        test.key(Qt.Key_G, Qt.ShiftModifier)
        test.codeFlick = test.find(page, i => i.flickableDirection === Flickable.HorizontalFlick && i.contentWidth > i.width + 300)
        if (!test.codeFlick) test.fail("a long diff line should scroll sideways instead of being cut off")
        test.key(Qt.Key_L)
      } else if (stage === 5) {
        if (!(test.codeFlick.contentX > 0)) test.fail("l did not scroll the focused change's code sideways")
        var lv = test.find(page, i => String(i).indexOf("QQuickListView") === 0)
        lv.contentY = lv.contentHeight - lv.height
        var x0 = test.codeFlick.contentX, y0 = lv.contentY, p = test.codeFlick.mapToItem(page, 50, 10)
        input.mouseWheel(page, p.x, p.y, Qt.NoButton, Qt.NoModifier, 120, 0, 0)
        if (!(test.codeFlick.contentX < x0 - 50) || lv.contentY !== y0) test.fail("a sideways wheel should move the code at the family scroll speed, not the page")
      } else if (stage === 6) {
        var lv = test.find(page, i => String(i).indexOf("QQuickListView") === 0)
        lv.contentY = lv.contentHeight - lv.height
        var x0 = test.codeFlick.contentX, y0 = lv.contentY, p = test.codeFlick.mapToItem(page, 50, 10)
        input.mouseWheel(page, p.x, p.y, Qt.NoButton, Qt.NoModifier, 0, 120, 0)
        if (!(lv.contentY < y0) || test.codeFlick.contentX !== x0) test.fail("an up/down wheel over code should still scroll the page")
        console.log("PASS: activity is one timeline of code changes: tool edits with their reason and diff, commits made outside the edit tool, the ask shown once per run of changes, whole-file writes summarised, history backfilled once per session including late arrivals, and Enter opens the changed file at its line")
        Qt.quit()
      }
      stage++
    }
  }
}

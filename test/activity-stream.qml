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
  property var walk: null
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
  function key(k, mods) { input.keyClick(k, mods || Qt.NoModifier, 0); find(page, i => String(i).indexOf("QQuickListView") === 0).forceLayout() }
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
          { type: "message", id: "gr", timestamp: new Date(test.t0 - 110000).toISOString(), message: { role: "user", timestamp: test.t0 - 110000,
            content: [{ type: "text", text: "Review PR 42" }] } },
          { type: "message", id: "gr1", message: { role: "assistant", timestamp: test.t0 - 109000, content: [
            { type: "toolCall", id: "ew", name: "write", arguments: { path: "/h/notes/storage/reviews/pr-42.md",
              content: "# PR #42 \u2014 fix(rail): keep focus\n\nfeat \u00b7 +3/-1\n\n## Verdict\n\n**Request changes.** Focus is lost on reload. More detail here.\n\n## Findings\n\n### Blocker \u00b7 `a.qml:1`\n\nx\n\n### Nit \u00b7 `b.qml:2`\n\ny\n\n## Verification\n\n### Blocker in prose does not count\n" } }] } },
          { type: "message", id: "grr", message: { role: "toolResult", toolCallId: "ew", timestamp: test.t0 - 108500 } },
          { type: "message", id: "gr2", message: { role: "assistant", timestamp: test.t0 - 108000, content: [{ type: "text", text: "\u27e2 Reviewed PR #42 and wrote the review (request changes, 2 findings)." }] } },
          { type: "message", id: "gq", timestamp: new Date(test.t0 - 107000).toISOString(), message: { role: "user", timestamp: test.t0 - 107000,
            content: [{ type: "text", text: "Ok so. Hm, where are we on the branch?" }] } },
          { type: "message", id: "gq1", message: { role: "assistant", timestamp: test.t0 - 106000, content: [{ type: "thinking", thinking: "Weighing the branch state" }, { type: "text", text: "**No change:** the branch still sits at last week's merge. It's committed as abc1234def, not pushed.\n\nDetails follow.\n\n\u27e2 Answer only; nothing on the branch has changed since last week." }] } },
          { type: "message", id: "gd", timestamp: new Date(test.t0 - 105000).toISOString(), message: { role: "user", timestamp: test.t0 - 105000,
            content: [{ type: "text", text: "Drop the loader" }] } },
          { type: "message", id: "gd1", message: { role: "assistant", timestamp: test.t0 - 104000, content: [
            { type: "toolCall", id: "ed", name: "edit", arguments: { path: "/r/Loader.qml", edits: [] } }] } },
          { type: "message", id: "gdr", message: { role: "toolResult", toolCallId: "ed", timestamp: test.t0 - 103500, details: { diff:
            "  4 ctx\n- 5   readonly property int legacyDepth: 3\n- 6   function loadLegacy(path) {\n- 7     var deepBodyLine = path.split(1)\n- 8     return deepBodyLine\n- 9   }\n-10   signal legacyLoaded()\n 11 ctx" } } },
          { type: "message", id: "gd2", message: { role: "assistant", timestamp: test.t0 - 103000, content: [{ type: "text", text: "\u27e2 Dropped the legacy loader." }] } },
          { type: "message", id: "gc", timestamp: new Date(test.t0 - 102000).toISOString(), message: { role: "user", timestamp: test.t0 - 102000,
            content: [{ type: "text", text: "\u21c4 coordinator\ncoordinator: posted PR #9 as a comment (head abc1234)." }] } },
          { type: "message", id: "gc1", message: { role: "assistant", timestamp: test.t0 - 101000, content: [{ type: "text", text: "3 of 4 reviews are now posted.\n\n\u27e2 The reviewer will post the rest." }] } },
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
            content: [{ type: "text", text: "Fix the shell script" }] } },
          { type: "message", id: "g0", timestamp: new Date(test.t0 - 3 * 86400000).toISOString(), message: { role: "user", timestamp: test.t0 - 3 * 86400000,
            content: [{ type: "text", text: "Old ask" }] } },
          { type: "message", id: "g01", message: { role: "assistant", timestamp: test.t0 - 3 * 86400000 + 500, content: [
            { type: "text", text: "Older: hook the cockpit check into Older so the old thing runs." },
            { type: "toolCall", id: "eo", name: "edit", arguments: { path: "/r/Older.qml", edits: [] } },
            { type: "toolCall", id: "et", name: "edit", arguments: { path: "/r/test/older.test.qml", edits: [] } }] } },
          { type: "message", id: "rt", message: { role: "toolResult", toolCallId: "et", timestamp: test.t0 - 3 * 86400000 + 600, details: { diff: "+ 1 expect(checkCockpit()).toBe(done) // old thing check cockpit" } } },
          { type: "message", id: "ro", message: { role: "toolResult", toolCallId: "eo", timestamp: test.t0 - 3 * 86400000 + 600, details: { diff: "+ 1 older\n  2 ctx\n+ 3 const done = checkCockpit()" } } },
          { type: "message", id: "g00", message: { role: "assistant", timestamp: test.t0 - 3 * 86400000 + 1000, content: [{ type: "text", text: "\u27e2 Old thing done; check it in your Cockpit." }] } }] } })
        // The same transcript again must not duplicate rows.
        test.event({ type: "response", command: "get_entries", session: "alpha", success: true, data: { entries: [
          { type: "message", id: "a2", message: { role: "assistant", timestamp: test.t0 + 5000, content: [{ type: "text", text: "\u27e2 Activity view renders history." }] } }] } })
      } else if (stage === 3) {
        if (!test.visibleText("Fix via shell") && waits++ < 20) return
        var asked = test.sent.filter(m => m.type === "get_entries").map(m => m.session).sort().join(",")
        if (asked !== "alpha,beta,gamma") test.fail("history was requested for " + asked)
        var kinds = state.activity.map(r => r.kind).sort().join(",")
        if (kinds !== "edit,edit,edit,edit,edit,edit,edit,prompt,prompt,prompt,prompt,prompt,prompt,prompt,summary,summary,summary,summary,summary,summary,task") test.fail("history rows were " + kinds)
        var prompt = state.activity.find(r => r.kind === "prompt" && r.text !== "Review PR 42" && r.text !== "Ok so. Hm, where are we on the branch?" && r.text !== "Drop the loader" && r.from !== "coordinator")
        if (prompt.from !== "nixos" || prompt.text !== "Build the activity view") test.fail("relayed prompt lost its sender: " + JSON.stringify(prompt))
        if (!test.hasText("</font>&nbsp;&nbsp;fix(rail): keep focus") || !test.visibleText("Changes requested") || !test.hasText("1 blocker</font> \u00b7 1 nit")
            || !test.visibleText("Focus is lost on reload.") || test.hasText("Reviewed PR #42"))
          test.fail("a review card should show the PR, its verdict, the findings by severity and the one-line why")
        var end = test.find(page, i => i.visible && i.objectName === "activityEnd")
        var newest = page.cards.reduce((n, c) => Math.max(n, c.at), 0)
        if (!end || end.text !== "Up to date \u00b7 latest " + page.clock(newest)) test.fail("the end of the list should say it is the latest activity and when that was, got " + (end && end.text))
        var chip = test.find(page, i => i.visible && i.objectName === "relayChip")
        if (!chip || !test.visibleText("coordinator") || !test.visibleText("The reviewer will post the rest") || test.hasText("posted PR #9"))
          test.fail("a relayed ask should show its sender as a chip and the outcome as its headline, not the relayed text")
        if (test.find(page, i => i.objectName === "activityList").width < page.width - 64) test.fail("the activity column should use the page's width")
        var qa = test.find(page, i => i.visible && i.objectName === "cardHead" && String(i.text).indexOf("Answer only") >= 0)
        if (!qa || qa.text !== "Answer only; nothing on the branch has changed since last week" || test.visibleText("Where are we on the branch?"))
          test.fail("an ask answered without edits should headline its closing outcome line, not the ask")
        if (!test.hasText("loadLegacy") || !test.hasText("legacyLoaded") || !test.hasText("legacyDepth") || test.hasText("deepBodyLine"))
          test.fail("a change that only removed code should list what was removed, not show the first lines of it")
        var removedCode = test.find(page, i => i.visible && String(i.text || "").indexOf("legacyDepth") >= 0)
        for (var ancestor = removedCode; ancestor && ancestor !== page; ancestor = ancestor.parent)
          if (ancestor.opacity !== 1) test.fail("removed code in activity previews should stay at full contrast")
        if (!Qt.colorEqual(removedCode.parent.children[0].color, Theme.red))
          test.fail("removed preview code should keep its red diff marker")
        if (!test.visibleText("Activity view renders history")) test.fail("an ask's card should say its outcome as a short headline")
        var fold = page.rows.find(r => r.kind === "fold")
        if (!fold || fold.count !== 1 || test.hasText("Old thing done")) test.fail("a past day should fold to one row with its ask count")
        var od = {}; od[fold.text] = true; page.openDays = od
        test.find(page, i => String(i).indexOf("QQuickListView") === 0).forceLayout()
        if (!test.hasText("checkCockpit") || test.visibleText("older") || test.hasText("toBe")) test.fail("a card's preview should show the source code that matches what the agent said it did, not the test")
        var names = []; test.find(page, i => { if (i.visible && (i.text === "Older.qml" || i.text === "older.test.qml")) names.push(i.text); return false })
        names = names.filter((n, k) => names.indexOf(n) === k)
        if (names.join() !== "Older.qml" || !test.hasText("+ tests</font>")) test.fail("source files get change cards; tests only tag the outcome: " + names)
        if (!test.visibleText("hook the cockpit check into Older so the old thing runs")) test.fail("each file should say what was done in it")
        page.openDays = ({})
        if (test.find(page, i => i.visible && i.color !== undefined && i.x === 0 && i.width > 0 && i.width <= 4 && i.height > 20))
          test.fail("sessions are told apart by their name header, not a gutter line: gutter lines are for diffs")
        if (page.cards.filter(c => c.ctx.text === "Activity view").length !== 1) test.fail("one card per ask")
        if (test.visibleText("Activity view")) test.fail("an unfocused card should be one line: what was done, not also the ask")
        if (page.rows.filter(r => r.kind === "who" && r.sid === "gamma").length !== 1) test.fail("the session name should head its run of cards once")
        if (!test.visibleText("Rail.qml") || !test.visibleText("New.qml") || !test.visibleText("The rail needs a hook so the page can open files") || !test.hasText('</font>&nbsp;y:&nbsp;<font'))
          test.fail("a folded card should show at a glance what changed: the file and the declaration it added")
        if (!test.visibleText("Fix via shell")) test.fail("a commit made outside the edit tool is missing")
        var themeWas = Theme.mode; Theme.mode = "light"
        var gbox = test.find(page, i => i.visible && i.objectName === "glanceBox")
        if (!gbox || !Qt.colorEqual(gbox.color, "#ffffff")) test.fail("code previews should sit on white in light mode")
        Theme.mode = themeWas
        if (test.visibleText("init")) test.fail("a commit no session was active before belongs to nobody, not to whichever session sits in that repo")
        var work = page.cards.find(c => c.ctx.text === "Activity view"), shellFix = page.cards.find(c => c.changes.some(e => e.commit))
        var scored = {}
        scored[work.jid] = { key: 0.9 }
        scored[shellFix.jid] = { key: 0.2 }
        page.jev = scored
        if (test.visibleText("f.txt")) test.fail("a minor ask should shrink to one line")
        for (var up = test.find(page, i => i.visible && String(i.text || "").indexOf("Fix via shell") >= 0); up && up !== page; up = up.parent)
          if (up.opacity !== 1) test.fail("a minor ask should shrink, not fade: its text must stay readable")
        page.forceActiveFocus(); test.key(Qt.Key_F)
        if (test.visibleText("Fix via shell") || !test.visibleText("Activity view renders history")) test.fail("f should hide minor asks and keep important ones")
        test.key(Qt.Key_F)
        if (!test.visibleText("Fix via shell")) test.fail("f again should show every ask")
        state.sendPrompt("beta", "keep going")
        test.event({ type: "message_end", session: "beta", message: { role: "assistant", timestamp: Date.now(), content: [
          { type: "text", text: "Live needs its own file so the stream can follow it." }, { type: "toolCall", id: "live1", name: "edit", arguments: { path: "/r/Live.qml" } }] } })
        test.event({ type: "tool_execution_start", session: "beta", toolName: "edit", toolCallId: "live1", args: { path: "/r/Live.qml", edits: [] } })
        test.event({ type: "tool_execution_end", session: "beta", toolName: "read", toolCallId: "rd1", result: { details: {} } })
        test.event({ type: "tool_execution_end", session: "beta", toolName: "edit", toolCallId: "live1", result: { details: { diff: "+ 1 a" + "_".repeat(400) } } })
        var live = page.cards.find(c => c.sid === "beta"), js = Object.assign({}, page.jev); js[live.jid] = { key: 0.1 }; page.jev = js
        test.find(page, i => String(i).indexOf("QQuickListView") === 0).forceLayout()
        if (!test.hasText("a" + "_".repeat(100))) test.fail("a card still being worked on must keep showing its code, not be dimmed as minor")
        test.event({ type: "message_end", session: "beta", message: { role: "assistant", timestamp: Date.now(), content: [{ type: "text", text: "\u27e2 Beta shipped (`abc1234`)." }] } })
      } else if (stage === 4) {
        if (!test.visibleText("Beta shipped")) test.fail("the live ask's outcome is not on its card")
        if (test.hasText("keep going")) test.fail("a prompt with an outcome should give its heading to the outcome")
        var lvs = test.find(page, i => String(i).indexOf("QQuickListView") === 0), inList = t => !!test.find(lvs, i => i.visible && String(i.text || "").indexOf(t) >= 0)
        if (inList("streaming") || inList("thinking") || inList("working")) test.fail("live status does not belong on the activity page")
        page.forceActiveFocus()
        var before = page.cursorPoint()
        if (!before) test.fail("no cursor dot on the focused page")
        test.key(Qt.Key_Return)
        if (String(test.opened) !== "beta:/r/Live.qml:1") test.fail("Enter on the last change should open its file, got " + test.opened)
        if (!test.hasText("a" + "_".repeat(100))) test.fail("a card should show its code without unfolding")
        while (!(page.currentRow.kind === "card" && page.currentRow.ctx.text === "Activity view") && page.cursor > 0) test.key(Qt.Key_K, Qt.ShiftModifier)
        if (page.currentRow.ctx.text !== "Activity view") test.fail("K should jump outcome by outcome, got " + JSON.stringify(page.currentRow))
        if (test.visibleText("Activity view")) test.fail("the outcome, not the ask, heads its changes")
        var lv = test.find(page, i => String(i).indexOf("QQuickListView") === 0), h0 = lv.contentHeight
        if (!test.hasText('<font color="' + Theme.syntaxOperator + '">=</font>&nbsp;<font color="' + Theme.syntaxNumber + '">1</font>'))
          test.fail("change code is not in the Neovim theme's operator/number colors")
        test.key(Qt.Key_J)
        if (page.currentRow.kind !== "file" || page.currentRow.f.name !== "Rail.qml") test.fail("j from an outcome should land on its first change, got " + JSON.stringify(page.currentRow.f))
        if (!page.cursorPoint()) test.fail("a change should carry the cursor dot")
        test.key(Qt.Key_Return)
        if (test.opened[1] !== "alpha:/r/Rail.qml:10") test.fail("Enter should open the change's file at its first changed line, got " + test.opened)
        test.key(Qt.Key_J)
        lv.forceLayout()
        if (page.currentRow.kind !== "file" || page.currentRow.f.name !== "New.qml") test.fail("j should step to the next change")
        if (Math.abs(lv.contentHeight - h0) > 0.5) test.fail("moving between changes must not resize anything: " + h0 + " -> " + lv.contentHeight)
        test.key(Qt.Key_Return)
        if (test.opened[2] !== "alpha:/r/New.qml:1") test.fail("Enter on the second change opened " + test.opened)
        test.key(Qt.Key_K)
        if (page.currentRow.f.name !== "Rail.qml") test.fail("k should step back a change")
        while (page.currentRow.sid !== "gamma" && page.cursor < page.rows.length - 1) test.key(Qt.Key_J, Qt.ShiftModifier)
        if (page.currentRow.kind !== "card" || !page.currentRow.bare) test.fail("a dimmed outcome should stand alone, without its changes")
        var js2 = Object.assign({}, page.jev); js2[page.currentRow.jid] = { key: 0.9 }; page.jev = js2
        var names = page.rows.filter(r => r.kind === "file" && r.sid === "gamma").map(r => r.f.path).join()
        if (names !== test.repo + "/f.txt," + test.repo + "/g.txt") test.fail("the commit should become one change per file, got " + names)
        if (!test.hasText("B")) test.fail("the commit's changed line is not shown")
        if (test.visibleText("Fix via shell") && page.rows.filter(r => r.kind === "file" && r.sid === "gamma" && r.why).length > 1) test.fail("a shared commit message should not repeat on every change")
        test.key(Qt.Key_J); test.key(Qt.Key_J); test.key(Qt.Key_Return)
        if (test.opened[3] !== "gamma:" + test.repo + "/g.txt:1") test.fail("j j then Enter should open g.txt, got " + test.opened)
        var composed = 0; page.composeRequested.connect(() => composed++)
        test.key(Qt.Key_I)
        if (composed !== 1) test.fail("i should ask to focus the rail's input")
        test.key(Qt.Key_S)
        if (test.opened[4] !== "gamma") test.fail("s did not open the card's session: " + test.opened)
        var lvh = test.find(page, i => String(i).indexOf("QQuickListView") === 0)
        page.select(page.rows.findIndex(r => page.stop(r)))
        var y0 = lvh.itemAtIndex(page.cursor).y, c0 = page.cursor
        test.key(Qt.Key_D, Qt.ControlModifier)
        var y1 = lvh.itemAtIndex(page.cursor).y
        if (page.cursor <= c0 || (y1 - y0 < lvh.height / 2 && page.rows.slice(page.cursor + 1).some(r => page.stop(r)))) test.fail("ctrl-d should move about half a screen down, " + y0 + " -> " + y1 + " of " + lvh.height)
        test.key(Qt.Key_U, Qt.ControlModifier)
        if (page.cursor !== c0) test.fail("ctrl-u should come back up, got " + page.cursor + " not " + c0)
      } else if (stage === 5) {
        page.anchors.fill = undefined; page.width = 1100; page.height = 360
        test.key(Qt.Key_G, Qt.ShiftModifier)
        test.walk = { dir: Qt.Key_K, steps: 0 }
      } else if (stage === 6) {
        var lv = test.find(page, i => String(i).indexOf("QQuickListView") === 0), w = test.walk
        if (w.top !== undefined) {
          if (Math.abs(lv.contentHeight - w.height) > 0.5) test.fail("step " + w.steps + ": moving the cursor resized rows, " + w.height + " -> " + lv.contentHeight)
          var item = lv.itemAtIndex(page.cursor), top = item.y - lv.contentY, bottom = top + item.height
          if (top < -1 || (bottom > lv.height + 1 && top > 1)) test.fail("step " + w.steps + ": the landed row is off screen at " + [top, bottom])
          if (w.top >= 0 && w.top + item.height <= lv.height && Math.abs(top - w.top) > 1 && page.cursor !== page.rows.length - 1)
            test.fail("step " + w.steps + ": the viewport jumped — the landed row moved from " + w.top + " to " + top + " though it fit where it was")
        }
        if (w.steps === 6) w.dir = Qt.Key_J
        if (w.steps === 12) {
          test.event({ type: "message_end", session: "gamma", message: { role: "assistant", timestamp: Date.now(), content: [
            { type: "toolCall", id: "lw", name: "write", arguments: { path: "/h/notes/storage/reviews/pr-43.md",
              content: "# PR #43 \u2014 feat: live review\n\n## Verdict\n\n**Approve.** Clean and tested.\n\n## Findings\n\nNone.\n" } }] } })
          test.event({ type: "tool_execution_start", session: "gamma", toolName: "write", toolCallId: "lw", args: { path: "/h/notes/storage/reviews/pr-43.md" } })
          test.event({ type: "tool_execution_end", session: "gamma", toolName: "write", toolCallId: "lw", result: { details: {} } })
          var lr = page.cards.find(c => c.changes.some(e => e.review && e.review.pr === "43"))
          if (!lr || lr.changes.slice(-1)[0].review.verdict !== "approve") test.fail("a review written live should become a review card: " + JSON.stringify(lr && lr.changes.map(e => e.review)))
          test.event({ type: "message_end", session: "alpha", message: { role: "user", timestamp: Date.now(), content: [{ type: "text", text: "One more thing" }] } })
          test.event({ type: "message_end", session: "alpha", message: { role: "assistant", timestamp: Date.now(), content: [{ type: "text", text: "\u27e2 Did one more thing." }] } })
          var heads = {}
          for (var hr of page.rows.filter(r => r.kind === "who")) heads[hr.sid] = (heads[hr.sid] || 0) + 1
          if (Object.values(heads).some(n => n > 1)) test.fail("each session should head one block per day, got " + JSON.stringify(heads))
          var last = page.rows.filter(r => r.kind === "card").pop()
          if (!last || last.sid !== "alpha") test.fail("the session with the newest activity should be the last block")
          console.log("PASS: activity is one card per ask with its outcome and files, each headed by its closing outcome with one change per file beneath, j/k walking changes and J/K outcomes without resizing, commits made outside the edit tool, history backfilled once per session including late arrivals, and Enter opens the changed file at its line")
        Qt.quit()
        }
        var dest = page.cursor, step = w.dir === Qt.Key_K ? -1 : 1
        for (dest += step; dest >= 0 && dest < page.rows.length && !page.stop(page.rows[dest]); dest += step);
        var it = lv.itemAtIndex(dest)
        w.top = it ? it.y - lv.contentY : -1; w.height = lv.contentHeight
        test.key(w.dir); w.steps++
        return
      }
      stage++
    }
  }
}

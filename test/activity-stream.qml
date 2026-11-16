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
  property var yanks: []
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
      onYanked: text => test.yanks.push(text)
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
        if (kinds !== "edit,edit,edit,edit,edit,prompt,prompt,prompt,summary,summary,task") test.fail("history rows were " + kinds)
        var prompt = state.activity.find(r => r.kind === "prompt")
        if (prompt.from !== "nixos" || prompt.text !== "Build the activity view") test.fail("relayed prompt lost its sender: " + JSON.stringify(prompt))
        if (!test.visibleText("Activity view renders history")) test.fail("an ask's card should say its outcome as a short headline")
        var fold = page.rows.find(r => r.kind === "fold")
        if (!fold || fold.count !== 1 || test.hasText("Old thing done")) test.fail("a past day should fold to one row with its ask count")
        var od = {}; od[fold.text] = true; page.openDays = od
        test.find(page, i => String(i).indexOf("QQuickListView") === 0).forceLayout()
        if (!test.hasText("checkCockpit") || test.visibleText("older") || test.hasText("toBe")) test.fail("a card's preview should show the source code that matches what the agent said it did, not the test")
        var names = []; test.find(page, i => { if (i.visible && (i.text === "Older.qml" || i.text === "older.test.qml")) names.push(i.text); return false })
        names = names.filter((n, k) => names.indexOf(n) === k)
        if (names.join() !== "Older.qml,older.test.qml") test.fail("each file should be listed, source before tests: " + names)
        if (!test.visibleText("hook the cockpit check into Older so the old thing runs")) test.fail("each file should say what was done in it")
        page.openDays = ({})
        if (!test.find(page, i => i.visible && i.color !== undefined && i.width === 3 && Qt.colorEqual(i.color, page.hueFor("gamma"))))
          test.fail("a session's cards should carry its colour bar")
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
        if (page.currentRow.kind !== "change" || !test.visibleText("Live needs its own file so the stream can follow it.")) test.fail("Enter on a card should unfold its edits with their reasons")
        if (!test.visibleText("Live.qml")) test.fail("live edit not shown")
        if (!test.hasText("a" + "_".repeat(100))) test.fail("an unfolded card's edits should show their diff without another Enter")
        test.key(Qt.Key_Return)
        if (page.codeFile !== 0 || test.opened.length) test.fail("Enter on an edit should step into its code, not open the file")
        test.key(Qt.Key_Return)
        if (String(test.opened) !== "beta:/r/Live.qml:1") test.fail("Enter on a code line opened " + test.opened)
        test.key(Qt.Key_Escape)
        if (page.codeFile !== -1 || page.currentRow.kind !== "change") test.fail("Esc should leave the code but stay on the edit")
        test.key(Qt.Key_K)
        if (page.currentRow.kind !== "card" || !page.cursorPoint() || page.cursorPoint().y >= before.y + 1) test.fail("k from the first edit should land on its card")
        test.key(Qt.Key_K); test.key(Qt.Key_K)
        if (!page.currentRow.ctx || page.currentRow.ctx.text !== "Activity view") test.fail("k should step card by card, got " + JSON.stringify(page.currentRow.ctx))
        if (test.visibleText("Activity view")) test.fail("focusing a card must not grow it")
        test.key(Qt.Key_Return)
        if (!test.visibleText("Activity view") || !test.visibleText("Rail.qml") || !test.visibleText("New.qml") || !test.visibleText("+2") || !test.visibleText("-1"))
          test.fail("the unfolded card should show its ask and its files with counts")
        if (!test.hasText("&nbsp;&nbsp;</font>ctx")) test.fail("an unfolded card's edit should show its full diff right away")
        if (!test.visibleText("The rail needs a hook so the page can open files.")) test.fail("the agent's reason for the edit is not shown when unfolded")
        if (test.visibleText("Live needs its own file so the stream can follow it.")) test.fail("unfolding one card should fold the other")
        test.key(Qt.Key_Return)
        if (page.codeLine !== 1 || page.codeCol !== 0) test.fail("the code cursor should start on the first changed line: " + [page.codeLine, page.codeCol])
        var at2 = (l, c, what) => { if (page.codeLine !== l || page.codeCol !== c) test.fail(what + ": cursor at " + [page.codeLine, page.codeCol] + ", wanted " + [l, c]) }
        test.key(Qt.Key_W); at2(1, 2, "w")
        test.key(Qt.Key_W); at2(1, 4, "w again")
        test.key(Qt.Key_E); at2(1, 7, "e")
        test.key(Qt.Key_B); at2(1, 6, "b")
        test.key(Qt.Key_Dollar); at2(1, 11, "$")
        test.key(Qt.Key_0); at2(1, 0, "0")
        test.key(Qt.Key_L); test.key(Qt.Key_H); test.key(Qt.Key_H); at2(1, 0, "h stops at the line start")
        test.key(Qt.Key_J); test.key(Qt.Key_W); at2(2, 9, "j then w")
        test.key(Qt.Key_V); test.key(Qt.Key_E); test.key(Qt.Key_Y)
        if (test.yanks[0] !== "string") test.fail("v e y should yank the word, got " + test.yanks)
        test.key(Qt.Key_V, Qt.ShiftModifier); test.key(Qt.Key_K); test.key(Qt.Key_Y)
        if (test.yanks[1] !== "x = 1 // set\nproperty string y: Text.Wrap") test.fail("V k y should yank both lines, got " + JSON.stringify(test.yanks[1]))
        test.key(Qt.Key_G, Qt.ShiftModifier); at2(3, 0, "G")
        test.key(Qt.Key_G); test.key(Qt.Key_G); at2(0, 0, "gg")
        test.key(Qt.Key_D, Qt.ControlModifier); at2(3, 0, "ctrl-d")
        test.key(Qt.Key_U, Qt.ControlModifier); at2(0, 0, "ctrl-u")
        test.key(Qt.Key_Y); test.key(Qt.Key_Y)
        if (test.yanks[2] !== "ctx") test.fail("yy should yank the line, got " + test.yanks[2])
        if (test.opened.length !== 1) test.fail("vim keys should not open anything: " + test.opened)
        test.key(Qt.Key_J); test.key(Qt.Key_Return)
        if (test.opened[1] !== "alpha:/r/Rail.qml:10") test.fail("Enter on a code line should open it at that line, got " + test.opened)
        test.key(Qt.Key_Escape)
        if (!test.hasText("&nbsp;&nbsp;</font>x") || !test.hasText("&nbsp;&nbsp;</font>ctx")) test.fail("the focused change should show its full diff, the change with its context")
        if (!test.hasText('</font>x&nbsp;<font color="' + Theme.syntaxOperator + '">=</font>&nbsp;<font color="' + Theme.syntaxNumber + '">1</font>&nbsp;<i><font color="' + Theme.syntaxComment + '">//&nbsp;set</font></i>'))
          test.fail("diff code is not in the Neovim theme's operator/number/comment colors")
        if (!test.hasText('<font color="' + Theme.syntaxType + '">string</font>&nbsp;y:&nbsp;<font color="' + Theme.syntaxType + '">Text</font>.Wrap'))
          test.fail("QML types are not in the Neovim theme's type color")
        if (!test.hasText('&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</font><font color="' + Theme.red + '">z</font>'))
          test.fail("a removed line should read like hunk-nvim's ghost line: red, unhighlighted, unnumbered")
        test.key(Qt.Key_J)
        if (!test.visibleText("Wrote the whole file \u00b7 Enter opens it")) test.fail("a written file should be summarised, not dumped")
        test.key(Qt.Key_Return)
        if (test.opened[2] !== "alpha:/r/New.qml:1") test.fail("j then Enter inside a card opened " + test.opened)
        test.key(Qt.Key_Escape)
        if (page.currentRow.kind !== "card" || test.visibleText("The rail needs a hook so the page can open files.")) test.fail("Esc should fold the card back")
        test.key(Qt.Key_J); test.key(Qt.Key_Return)
        if (page.currentRow.why !== "Fix via shell" || page.currentRow.files.length !== 2) test.fail("expected the two-file commit, got " + page.currentRow.why)
        if (!test.hasText("&nbsp;&nbsp;</font>B")) test.fail("the commit's changed line is not shown")
        var at = pred => { var it = test.find(page, i => i.visible && pred(String(i.text || ""))); return it ? it.mapToItem(page, 0, 0).y : NaN }
        var fy = at(t => t.endsWith("</font>f.txt")), by = at(t => t.endsWith("</font>B")), gy = at(t => t.endsWith("</font>g.txt")), Gy = at(t => t.endsWith("</font>G"))
        if (!(fy < by && by < gy && gy < Gy)) test.fail("each file of a commit should sit directly above its own diff: " + [fy, by, gy, Gy])
        test.key(Qt.Key_Return)
        if (test.opened.length !== 3 || page.itemIndex !== 0) test.fail("Enter on a change with several files should step inside it, not open one")
        test.key(Qt.Key_Return); test.key(Qt.Key_Return)
        if (test.opened[3] !== "gamma:" + test.repo + "/f.txt:2") test.fail("Enter inside a commit should open its first file: " + test.opened)
        test.key(Qt.Key_Escape); test.key(Qt.Key_J); test.key(Qt.Key_Return); test.key(Qt.Key_Return)
        if (test.opened[4] !== "gamma:" + test.repo + "/g.txt:1") test.fail("j then Enter inside a change should open the second file, got " + test.opened)
        test.key(Qt.Key_Escape); test.key(Qt.Key_Escape)
        if (page.itemIndex !== -1) test.fail("Esc should leave the change")
        test.opened.pop()
        test.key(Qt.Key_S)
        if (test.opened[4] !== "gamma") test.fail("s did not open the change's session: " + test.opened)
        test.key(Qt.Key_G, Qt.ShiftModifier); test.key(Qt.Key_Return)
        if (page.codeFile >= 0) test.key(Qt.Key_Escape)
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
        page.anchors.fill = undefined; page.width = 1100; page.height = 500
      } else if (stage === 7) {
        var lv = test.find(page, i => String(i).indexOf("QQuickListView") === 0)
        lv.contentY = lv.contentHeight - lv.height
        var x0 = test.codeFlick.contentX, y0 = lv.contentY, p = test.codeFlick.mapToItem(page, 50, 10)
        input.mouseWheel(page, p.x, p.y, Qt.NoButton, Qt.NoModifier, 0, 120, 0)
        if (lv.contentHeight <= lv.height) test.fail("the feed must overflow for this check, got " + lv.contentHeight + " in " + lv.height)
        if (!(lv.contentY < y0) || test.codeFlick.contentX !== x0) test.fail("an up/down wheel over code should still scroll the page")
        page.height = 200
        page.forceActiveFocus(); test.key(Qt.Key_Escape); test.key(Qt.Key_G); test.key(Qt.Key_J); test.key(Qt.Key_Return)
      } else if (stage === 8) {
        test.key(Qt.Key_K)
      } else if (stage === 9) {
        var lv = test.find(page, i => String(i).indexOf("QQuickListView") === 0), next = lv.itemAtIndex(page.cursor + 1)
        var p = next.mapToItem(page, 100, 12)
        if (p.y > page.height - 4) test.fail("the edit below the card should be partly in view, at " + p.y)
        input.mouseClick(page, p.x, p.y, Qt.LeftButton, Qt.NoModifier, 0)
      } else if (stage === 10) {
        var lv = test.find(page, i => String(i).indexOf("QQuickListView") === 0), item = lv.itemAtIndex(page.cursor)
        if (page.currentRow.kind !== "change") test.fail("expected an unfolded edit, got " + page.currentRow.kind)
        var top = item.y, bottom = item.y + item.height, viewBottom = lv.contentY + lv.height
        if (top < lv.contentY - 1 || (bottom > viewBottom + 1 && Math.abs(top - lv.contentY) > 1))
          test.fail("the focused edit grew past the view without scrolling: " + [top, bottom, lv.contentY, viewBottom])
        page.height = 360
        while (page.openKey) test.key(Qt.Key_Escape)
        test.key(Qt.Key_G, Qt.ShiftModifier)
        test.walk = { dir: Qt.Key_K, steps: 0 }
      } else if (stage === 11) {
        var lv = test.find(page, i => String(i).indexOf("QQuickListView") === 0), w = test.walk
        if (w.top !== undefined) {
          if (Math.abs(lv.contentHeight - w.height) > 0.5) test.fail("step " + w.steps + ": moving the cursor resized rows, " + w.height + " -> " + lv.contentHeight)
          var item = lv.itemAtIndex(page.cursor), top = item.y - lv.contentY, bottom = top + item.height
          if (top < -1 || (bottom > lv.height + 1 && top > 1)) test.fail("step " + w.steps + ": the landed row is off screen at " + [top, bottom])
          if (w.top >= 0 && w.top + item.height <= lv.height && Math.abs(top - w.top) > 1)
            test.fail("step " + w.steps + ": the viewport jumped — the landed row moved from " + w.top + " to " + top + " though it fit where it was")
        }
        if (w.steps === 6) w.dir = Qt.Key_J
        if (w.steps === 12) {
          console.log("PASS: activity is one card per ask with its outcome and files, unfolding into tool edits with their reason and diff and commits made outside the edit tool, whole-file writes summarised, history backfilled once per session including late arrivals, and Enter opens the changed file at its line")
        Qt.quit()
        }
        var dest = page.cursor, step = w.dir === Qt.Key_K ? -1 : 1
        for (dest += step; dest >= 0 && dest < page.rows.length && !page.stop(page.rows[dest].kind); dest += step);
        var it = lv.itemAtIndex(dest)
        w.top = it ? it.y - lv.contentY : -1; w.height = lv.contentHeight
        test.key(w.dir); w.steps++
        return
      }
      stage++
    }
  }
}

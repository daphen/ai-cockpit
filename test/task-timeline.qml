import QtQuick
import QtTest
import QsLib
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  property int waits: 0
  property var sent: []
  property var expectedRows: [1, 3, 5, 9]
  AgentdState {
    id: state
    selectedSession: rail.selectedRaw
    function send(message) { test.sent = test.sent.concat([message]); return true }
  }
  FloatingWindow { visible: true; width: 720; height: 800
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "task-timeline-test"; focused: true
      TestEvent { id: input }
    }
    TaskTimeline { id: scaled; visible: false; width: 32; height: 16; segments: rail.taskSegments }
  }
  function find(item, name) {
    if (item.objectName === name) return item
    for (var i = 0; item.children && i < item.children.length; i++) {
      var match = find(item.children[i], name)
      if (match) return match
    }
    return null
  }
  function shownText(item) {
    if (!item || item.visible === false) return ""
    var text = typeof item.text === "string" ? item.text : ""
    for (var i = 0; item.children && i < item.children.length; i++) text += "\n" + shownText(item.children[i])
    return text
  }
  function notch(index, width, height, color) {
    var stroke = find(rail, "taskNotch-" + index)
    check(stroke && Math.abs(stroke.width - width) < 0.1 && Math.abs(stroke.height - height) < 0.1, "wrong horizontal notch geometry " + index)
    check(String(stroke.color) === String(color), "wrong notch color " + index + ": " + stroke.color + " expected " + color)
    check(stroke.radius === stroke.height / 2, "notch ends are not rounded")
  }
  function ready(value) {
    if (value) { waits = 0; return true }
    if (++waits > 8) throw new Error("feed did not settle")
    return false
  }
  function check(value, message) { if (!value) throw new Error(message) }
  function broadcast(message) { state.onLine(JSON.stringify(message), 0) }
  function history(entries, leaf) { broadcast({type:"response",command:"get_entries",session:"ticket",data:{entries:entries,leafId:leaf}}) }
  function entry(id, parent, role, text) {
    return {type:"message",id:id,parentId:parent,message:{role:role,content:[{type:"text",text:text}]}}
  }
  function marker(id, parent, action, title, outcome) {
    return {type:"custom",customType:"cockpit-session-task",id:id,parentId:parent,timestamp:"2026-09-10T10:00:00Z",data:{action:action,title:title,outcome:outcome || ""}}
  }
  function tasks() {
    return [entry("u0",null,"user","Before tasks"),
      marker("empty","u0","switch","No visible content"),
      marker("m1","empty","switch","Browser rendering"), entry("u1","m1","user","Browser request"), entry("a1","u1","assistant","Browser result"),
      marker("m2","a1","switch","Git review"), entry("u2","m2","user","Git request"), entry("a2","u2","assistant","Git result"),
      marker("m3","a2","switch","Browser rendering"), entry("u3","m3","user","Browser again"), entry("a3","u3","assistant","Browser fixed"),
      marker("done","a3","finish","Browser rendering","Recovered"), entry("u4","done","user","Between tasks"), entry("a4","u4","assistant","Ready"),
      marker("m4","a4","switch","Current task"), entry("u5","m4","user","Current request"), entry("a5","u5","assistant","Current result"),
      marker("other-branch","u0","switch","Wrong branch")]
  }
  Timer { interval: 250; repeat: true; running: true
    onTriggered: {
      if (test.phase === 0) test.broadcast({type:"roster",sessions:[{name:"ticket",id:"ticket",cwd:"/tmp",status:"idle"}]})
      else if (test.phase === 1) test.history([test.entry("u",null,"user","Hello"),test.entry("a","u","assistant","Normal reply")],"a")
      else if (test.phase === 2) {
        if (!test.ready(rail.probeProse().indexOf("Normal reply") >= 0)) return
        test.check(rail.taskSegments.length === 0 && rail.activeTask === "", "ordinary history invented a task")
        test.check(rail.probeProse().indexOf("Normal reply") >= 0, "ordinary prose changed: " + JSON.stringify({selected:rail.selectedRaw,feed:state.feedFor("ticket"),grouped:rail.groupedFeed,prose:rail.probeProse()}))
        test.history(test.tasks(),"a5")
      } else if (test.phase === 3) {
        var firstNotch = test.find(rail, "taskNotch-0")
        if (!test.ready(rail.taskSegments.length === 4 && rail.feedScrollState().count === 11 && firstNotch && Math.abs(firstNotch.color.a - Theme.dimmedFg.a) < 0.001)) return
        test.check(rail.taskSegments.length === 4, "repeated titles did not create separate segments: " + JSON.stringify({segments:rail.taskSegments,feed:state.feedFor("ticket"),selected:rail.selectedRaw}))
        test.check(rail.activeTask === "Current task", "wrong branch/finish affected active task")
        test.notch(0, 17, 2, Theme.dimmedFg)
        test.notch(3, 28, 3, Theme.cursor)
        test.check(rail.taskSegments[2].outcome === "Recovered" && rail.taskSegments[2].finishedAt.length > 0, "finish details lost")
        test.check(rail.taskSegments[0].title === rail.taskSegments[2].title, "returning to a task changed its identity")
        var taskLabel = test.find(rail,"activeTaskLabel")
        test.check(taskLabel.visible && taskLabel.width > 180, "active task subtitle missing or still width-capped")
        test.check(taskLabel.color === Theme.fg_muted && taskLabel.font.pixelSize < rail.fsName, "active task subtitle is not smaller and muted")
        for (var i = 0; i < 4; i++) test.check(rail.taskSegments[i].row === test.expectedRows[i], "incorrect rendered row index")
        rail.prefillTask()
        test.check(rail.composerText === "/task ", "pill did not prefill command")
        rail.prefillComposer("unfinished draft"); rail.prefillTask()
        test.check(rail.composerText === "unfinished draft", "task pill discarded a draft")
        rail.prefillComposer(""); rail.exitInsert()
        var timeline = test.find(rail,"sessionTaskTimeline")
        var first = test.find(timeline,"taskNotch-0").parent
        var last = test.find(timeline,"taskNotch-3").parent
        test.check(Math.abs(last.y - first.y - 24) < 0.1 && first.height === 8, "task stack is not compact")
        test.check(Math.abs((first.y + last.y + last.height) / 2 - timeline.height / 2) < 0.1, "task stack is not vertically centered")
        test.check(scaled.pitch === 4 && test.find(scaled,"taskNotch-3").parent.y + scaled.pitch <= scaled.height, "dense stack did not shrink to fit")
        test.check(!rail.groupedFeed.some(row => (row.items || []).some(item => item.tool === "task")), "task boundaries became transcript cards")
        test.check(test.shownText(rail).indexOf("Task · ") < 0 && test.shownText(rail).indexOf("Finished · ") < 0, "visible task boundary label leaked")
        var target = test.find(timeline,"taskNotch-2").parent
        var detailCard = test.find(timeline,"taskDetail-2")
        test.check(detailCard && detailCard.opacity === 0 && Math.abs(detailCard.y - detailCard.restingY + 3) < 0.1, "task popup did not start in the orb's hidden state")
        input.mouseClick(timeline, timeline.width / 2, target.y + target.height / 2, Qt.LeftButton, Qt.NoModifier, 0)
        input.mouseMove(timeline, timeline.width / 2, target.y + target.height / 2, 0, Qt.NoButton, Qt.NoModifier)
      } else if (test.phase === 4) {
        var shownDetail = test.find(rail,"taskDetail-2")
        test.check(test.shownText(test.find(rail,"sessionTaskTimeline")).indexOf("Recovered") >= 0, "hover did not show the finish outcome")
        test.check(shownDetail && shownDetail.opacity > 0.99 && Math.abs(shownDetail.y - shownDetail.restingY - 2) < 0.1, "task popup did not finish the orb fade-and-settle transition")
        test.notch(2, 21, 2, Theme.fg)
        test.notch(3, 28, 3, Theme.cursor)
        test.check(rail.activeTask === "Current task", "navigation changed task activity")
        test.check(rail.cur === rail.rSize + 5 && rail.scrollMode === "free", "timeline did not move the real feed cursor or leave follow")
        test.check(rail.curRowText().indexOf("Browser again") >= 0, "cursor landed on unrelated content")
        test.sent = []; state.submit("ticket","/task Browser rendering")
        test.check(test.sent.length === 1 && test.sent[0].type === "prompt" && String(test.sent[0].id).indexOf("cockpit-task:") === 0, "command was not sent as a control operation")
        test.check(!state.isBusy("ticket"), "task command falsely marked a model turn busy")
        test.broadcast({type:"response",command:"prompt",session:"ticket",id:test.sent[0].id,success:true})
        test.check(test.sent[1].type === "get_entries", "command acknowledgement did not refresh native boundaries")
        test.history(test.tasks(), "a5")
        test.broadcast({type:"tool_execution_end",session:"ticket",toolName:"session_task",result:{}})
        test.check(test.sent[2].type === "get_entries", "agent tool completion did not refresh boundaries")
        test.history([test.marker("only",null,"switch","Only task")],"only")
      } else if (test.phase === 5) {
        if (!test.ready(rail.activeTask === "Only task")) return
        test.check(rail.groupedFeed.length === 0 && rail.taskSegments.length === 0, "empty task fabricated a row or jump target")
        test.check(test.find(rail,"activeTaskLabel").visible, "empty current task lost its subtitle")
        test.history([test.marker("only",null,"switch","Only task"),test.entry("only-row","only","assistant","First visible answer")],"only-row")
      } else if (test.phase === 6) {
        if (!test.ready(rail.taskSegments.length === 1 && rail.groupedFeed.length === 1)) return
        test.find(rail,"sessionTaskTimeline").activate(0)
        test.check(rail.curRowText().indexOf("First visible answer") >= 0, "new task did not anchor to its first visible row")
        test.check(rail.scrollMode === "free", "last-row task jump unexpectedly enabled live follow")
        rail.debugNav("G")
        test.check(rail.scrollMode === "follow", "explicit bottom navigation did not restore follow")
        var many = [test.marker("old",null,"switch","Outside window")], parent = "old"
        for (var j = 0; j < 65; j++) { var id = "tail" + j; many.push(test.entry(id,parent,j%2 ? "assistant" : "user","Tail " + j)); parent = id }
        test.history(many,parent)
      } else if (test.phase === 7) {
        if (!test.ready(rail.taskSegments.length === 0)) return
        test.check(rail.taskSegments.length === 0 && rail.activeTask === "", "out-of-window task was fabricated")
        test.check(!test.find(rail,"sessionTaskTimeline").visible, "empty timeline still visible")
        test.history([test.marker("clipped","missing-parent","switch","Available tail"), test.entry("last","clipped","assistant","Tail result")],"last")
      } else if (test.phase === 8) {
        if (!test.ready(rail.activeTask === "Available tail")) return
        test.check(rail.taskSegments.length === 1 && rail.taskSegments[0].row === 0, "trimmed native branch could not anchor retained task")
        test.check(rail.activeTask === "Available tail", "trimmed branch active title lost")
        test.history([test.marker("start",null,"switch","Finished task"),test.entry("answer","start","assistant","Finished answer"),test.marker("finish","answer","finish","Finished task","Done")],"finish")
      } else if (test.phase === 9) {
        if (!test.ready(rail.activeTask === "" && rail.taskSegments.length === 1 && rail.taskSegments[0].title === "Finished task")) return
        test.check(rail.activeTask === "" && !rail.taskSegments.some(segment => segment.active), "finished task kept current styling")
        test.find(rail,"sessionTaskTimeline").activate(0)
      } else if (test.phase === 10) {
        test.notch(0, 21, 2, Theme.fg)
        test.check(rail.activeTask === "", "selecting finished history restarted activity")
        test.check(rail.groupedFeed.length === 1 && rail.curRowText().indexOf("Finished answer") >= 0, "finish boundary became a card or jump anchor")
        var shapes = [{fromHook:true}, {details:{strategy:"deterministic-auto-v3"}}, {fromHook:false,details:{strategy:"deterministic-auto-v3"}}, {fromHook:false}, {}, {fromHook:"true",details:{strategy:"other"}}]
        var entries = shapes.map((shape, i) => Object.assign({type:"compaction",id:"c" + i,parentId:i ? "c" + (i-1) : null}, shape))
        entries.push({type:"compaction",id:"excluded",parentId:"c0",fromHook:true})
        test.history(entries,"c5")
      } else if (test.phase === 11) {
        var words = state.feedFor("ticket").filter(item => item.kind === "sys").map(item => item.text)
        test.check(JSON.stringify(words) === JSON.stringify(["context rolled over","context rolled over","context rolled over","context compacted","context compacted","context compacted"]), "native compaction metadata/wording lost: " + JSON.stringify(words))
        console.log("PASS: compact centered minimap, hidden task cards, visible-row anchors, notch styles, navigation-only selection, hover, caps, follow and compaction")
        Qt.quit()
      }
      test.phase++
    }
  }
}

import QtQuick
import QtTest
import Quickshell
import QsLib
import "."
ShellRoot {
  id: test
  property int phase: 0
  property int waits: 0
  AgentdState {
    id: state
    selectedSession: rail.selectedRaw
    function send(message) { return true }
  }
  FloatingWindow {
    id: win
    visible: true; implicitWidth: 720; implicitHeight: 800
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "session-tabs-test"; focused: true }
    TestEvent { id: input }
  }
  function find(item, name, sid) {
    if (!item) return null
    if (item.objectName === name && (!sid || item.sid === sid)) return item
    for (var child of item.children || []) { var hit = find(child, name, sid); if (hit) return hit }
    return null
  }
  function tabs(item) {
    var found = item.objectName === "sessionTab" ? [item] : []
    for (var child of item.children || []) found = found.concat(tabs(child))
    return found
  }
  function check(value, message) { if (!value) throw new Error(message) }
  function key(k, mods) { input.keyClick(k, mods || Qt.NoModifier, 0) }
  function roster() {
    var sessions = [{id:"lovable",name:"lovable",cwd:"/tmp",status:"idle"},
                    {id:"helper",name:"helper",cwd:"/tmp",parent:"worker-2",status:"streaming"}]
    for (var i = 0; i < 10; i++) sessions.push({id:"worker-"+i,name:"worker-"+i,cwd:"/tmp",status:i%2 ? "streaming" : "idle"})
    state.onLine(JSON.stringify({type:"roster",sessions:sessions}),0)
    state.pendingSends = { helper: true }; state.pendingGen++
  }
  function history(title) {
    state.onLine(JSON.stringify({type:"response",command:"get_entries",session:rail.selectedRaw,data:{leafId:"task",entries:title ? [{type:"custom",id:"task",customType:"cockpit-session-task",data:{action:"switch",title:title}}] : []}}),0)
  }
  function inView(sid) {
    var strip = find(rail, "sessionTabStrip"), tab = find(strip, "sessionTab", sid)
    if (!tab) return false
    var p = tab.mapToItem(strip, 0, 0)
    return p.x >= -0.5 && p.x + tab.width <= strip.width + 0.5
  }
  Timer {
    interval: 400; repeat: true; running: true
    onTriggered: {
      var strip = find(rail, "sessionTabStrip"), label = find(rail, "activeTaskLabel")
      if (test.phase === 0) {
        test.roster()
        rail.jumpToSession("lovable")
        test.history("Tab strip task")
      } else if (test.phase === 1) {
        if (rail.activeTask !== "Tab strip task" && test.waits++ < 8) return
        var all = test.tabs(strip)
        test.check(rail.rSize === 11 && all.length >= 4, "tabs must list every root session and no subagent: " + rail.rSize)
        test.check(!find(strip, "sessionTab", "helper"), "subagent got its own tab")
        test.check(find(strip, "sessionTab", "lovable").selected, "selected session lost its tab")
        test.check(strip.contentWidth > strip.width + 1, "crowded strip does not overflow into a scroll")
        test.check(test.inView("lovable"), "selected tab is outside the strip viewport")
        var frame = find(rail, "composerFrame")
        test.check(label.visible && label.text === "Tab strip task" && label.mapToItem(frame, 0, 0).y + label.height <= 0, "task line is not above the composer input")
        var status = find(rail, "composerStatus"), sp = status.mapToItem(frame, 0, 0)
        test.check(status.visible && sp.y >= 0 && sp.x + status.width <= frame.width + 8 && sp.x > frame.width / 2, "session status is not in the composer's bottom-right corner")
        var parentOrb = find(find(strip, "sessionTab", "worker-2"), "rootActivityOrb")
        test.check(parentOrb && parentOrb.running && parentOrb.visible, "subagent activity did not fold into its parent's tab")
        var idleOrb = find(find(strip, "sessionTab", "worker-9"), "rootActivityOrb")
        test.check(idleOrb && idleOrb.visible && idleOrb.motion < 1 && idleOrb.activityColors.length === 0, "idle tab does not show a still grey orb")
        test.check(idleOrb.idleBlur === 1 - idleOrb.motion && idleOrb.idleBlur > 0, "idle tab does not soften with its spin-down")
        rail.jumpToSession("worker-9")
      } else if (test.phase === 2) {
        test.check(test.inView("worker-9"), "switching to an off-screen tab did not scroll it into view")
        rail.enterInsert()
        test.key(Qt.Key_K, Qt.ControlModifier)
        test.check(!rail.insert && !rail.rosterExpanded, "C-k from the composer did not land on the feed")
        test.key(Qt.Key_K, Qt.ControlModifier)
        test.check(!rail.rosterExpanded, "second C-k left the feed for the tabs")
        test.key(Qt.Key_T, Qt.ControlModifier)
        test.check(rail.rosterExpanded && rail.cur === rail._rosterIndexOf("worker-9"), "C-t did not land on the selected tab")
        test.key(Qt.Key_H); test.key(Qt.Key_H)
        test.check(rail.cur === rail._rosterIndexOf("worker-7"), "h did not move left across tabs: " + rail.cur)
        test.key(Qt.Key_J)
        test.check(rail.cur === rail._rosterIndexOf("worker-7"), "j moved off the tabs")
        test.key(Qt.Key_L)
        test.check(rail.cur === rail._rosterIndexOf("worker-8"), "l did not move right across tabs")
        test.key(Qt.Key_Return)
        test.check(rail.selectedRaw === "worker-8", "Enter on a tab did not switch session")
      } else if (test.phase === 3) {
        test.check(test.inView("worker-8"), "chosen tab left the viewport")
        var order = () => rail.rosterList.map(r => r.rawName).slice(0, 3).join(",")
        test.check(order() === "worker-8,worker-9,lovable", "tabs are not ordered by recent selection: " + order())
        rail.exitInsert(); rail.focusRoster()
        rail.activeRaw = "worker-3"
        test.check(order() === "worker-8,worker-9,lovable", "tabs re-sorted while the tab list had focus: " + order())
        rail.enterInsert()
        test.check(order() === "worker-3,worker-8,worker-9", "tabs did not re-sort after the tab list lost focus: " + order())
        rail.exitInsert(); rail.focusRoster()
        test.key(Qt.Key_J, Qt.ControlModifier)
        test.check(rail.insert, "C-j from the tabs with an empty feed did not reach the composer")
        test.history("")
      } else if (test.phase === 4) {
        test.check(!label || !label.visible, "empty task still shows a task line")
        rail.exitInsert(); rail.focusRoster(); rail.cur = rail.rSize - 1
        test.key(Qt.Key_L)
        test.check(rail.cur === 0, "l on the last tab did not wrap to the first")
      } else if (test.phase === 5) {
        test.check(test.inView(rail.rosterList[0].rawName || rail.rosterList[0].name), "wrapped-to first tab is not in view")
        test.key(Qt.Key_H)
        test.check(rail.cur === rail.rSize - 1, "h on the first tab did not wrap to the last")
      } else if (test.phase === 6) {
        test.check(test.inView(rail.rosterList[rail.rSize - 1].rawName || rail.rosterList[rail.rSize - 1].name), "wrapped-to last tab is not in view")
        console.log("PASS: root-only tabs overflow into a scroll, keep the selected tab in view, fold subagent activity, and show the task line only when set, and h/l wrap around the ends")
        Qt.quit()
      }
      test.phase++
    }
  }
}

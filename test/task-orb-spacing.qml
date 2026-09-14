import QtQuick
import Quickshell
import "."

ShellRoot {
  id: test
  property int phase: 0
  property int waits: 0
  property string title: "Launch investigative spikes for DS Canvas demo follow-ups and verify every preview"
  AgentdState {
    id: state
    selectedSession: rail.selectedRaw
    function send(message) { return true }
  }
  FloatingWindow {
    id: win
    visible: true
    implicitWidth: 720
    implicitHeight: 800
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "task-spacing-test"; focused: true }
  }
  function find(item, name) {
    if (item.objectName === name) return item
    for (var child of item.children || []) { var hit = find(child, name); if (hit) return hit }
    return null
  }
  function markers(item) {
    var found = item.objectName === "sharedRosterOrb" ? [item] : []
    for (var child of item.children || []) found = found.concat(markers(child))
    return found
  }
  function box(item) { var p = item.mapToItem(rail, 0, 0); return { x: p.x, right: p.x + item.width, y: p.y, bottom: p.y + item.height } }
  function check(value, message) { if (!value) throw new Error(message) }
  function roster(streaming) {
    var sessions = [{id:"lovable",name:"lovable",cwd:"/tmp",status:streaming ? "streaming" : "idle"}]
    for (var i = 0; i < 10; i++) sessions.push({id:"worker-"+i,name:"worker-"+i,cwd:"/tmp",status:i%2 ? "streaming" : "idle"})
    state.onLine(JSON.stringify({type:"roster",sessions:sessions}),0)
  }
  function history(title) {
    state.onLine(JSON.stringify({type:"response",command:"get_entries",session:"lovable",data:{leafId:"task",entries:title ? [{type:"custom",id:"task",customType:"cockpit-session-task",data:{action:"switch",title:title}}] : []}}),0)
  }
  function spacing() {
    var label = find(rail,"activeTaskLabel"), orb = find(rail,"featuredHeaderOrb")
    check(label && label.visible, "task subtitle missing")
    check(label.parent.height === 52, "task must not enlarge the compact header")
    check(box(label).right + 8 <= box(orb).x, "task overlaps the featured orb's reserved column")
    var roots = markers(rail)
    check(roots.length >= 10, "fixture lacks a crowded orb row")
    for (var marker of roots) {
      if (!marker.visible) continue
      var b = box(marker), t = box(label)
      if (!rail.rosterExpanded) {
        var featured = box(orb)
        check(Math.abs((b.y + b.bottom) / 2 - (featured.y + featured.bottom) / 2) < 0.1, "selected indicator dropped below the shared orb row")
        check(orb.mapToItem(label.parent.parent, 0, 0).y >= 0, "featured orb is clipped above the header")
      }
      check(b.bottom + 4 <= t.y || b.y >= t.bottom + 4, "task overlaps a shared roster marker")
    }
    check(label.width > 0 && label.x + label.width <= label.parent.width, "subtitle escapes the header width")
  }
  Timer {
    interval: 450; repeat: true; running: true
    onTriggered: {
      if (test.phase === 0) test.roster(true)
      else if (test.phase === 1) { rail.jumpToSession("lovable"); rail.rosterOverride = false; test.history(test.title) }
      else if (test.phase === 2) {
        if (rail.activeTask !== test.title && test.waits++ < 8) return
        test.spacing(); win.implicitWidth = 480
      } else if (test.phase === 3) { test.spacing(); test.roster(false) }
      else if (test.phase === 4) { test.spacing(); rail.rosterOverride = true }
      else if (test.phase === 5) { test.spacing(); rail.rosterOverride = false; test.history("") }
      else if (test.phase === 6) {
        test.check(!test.find(rail,"activeTaskLabel").visible, "empty task still reserves a subtitle")
        console.log("PASS: task subtitle clears featured/shared orbs at wide/narrow widths, running/idle and expanded/collapsed")
        Qt.quit()
      }
      test.phase++
    }
  }
}

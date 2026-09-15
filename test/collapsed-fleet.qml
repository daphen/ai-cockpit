import QtQuick
import Quickshell
import Quickshell.Io
import QsLib
import "."

ShellRoot {
  id: test
  property int phase: 0
  property var mountedOrb: null
  SocketServer {
    active: true
    path: Quickshell.env("HOME") + "/agentd-personal.sock"
    handler: Socket {}
  }
  AgentdState {
    id: state
    configuredSockPaths: [Quickshell.env("HOME") + "/agentd-personal.sock"]
    selectedSession: rail.selectedRaw
    function send(message) { return true }
  }
  FloatingWindow {
    visible: true; implicitWidth: 720; implicitHeight: 800
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "fleet-test"; focused: true }
  }
  function find(item, name, sid) {
    if (!item) return null
    if (item.objectName === name && (!sid || (item.md && (item.md.rawName || item.md.name) === sid))) return item
    for (var child of item.children || []) { var hit = find(child, name, sid); if (hit) return hit }
    return null
  }
  function orb(sid) { return find(find(rail, "sharedRosterOrb", sid), "rootActivityOrb") }
  function check(value, message) { if (!value) throw new Error(message) }
  function roster(grandchild, sibling, parent) {
    state.onLine(JSON.stringify({type:"roster",sessions:[
      {id:"viewer",name:"viewer",cwd:"/tmp",status:"idle"},
      {id:"nixos",name:"nixos",cwd:"/tmp",status:parent || "idle"},
      {id:"child",name:"child",cwd:"/tmp",parent:"nixos",status:"idle"},
      {id:"grandchild",name:"grandchild",cwd:"/tmp",parent:"child",status:grandchild},
      {id:"sibling",name:"sibling",cwd:"/tmp",parent:"nixos",status:sibling},
      {id:"unrelated",name:"unrelated",cwd:"/tmp",status:"streaming"}
    ]}),0)
  }
  Timer {
    interval: 250; repeat: true; running: true
    onTriggered: {
      if (test.phase === 0) {
        if (!state.connected) return
        test.roster("streaming", "streaming")
      }
      else if (test.phase === 1) {
        rail.jumpToSession("viewer"); rail.rosterOverride = false
        state.onLine(JSON.stringify({type:"tool_execution_start",session:"grandchild",toolName:"read",toolCallId:"read-1"}),0)
        state.onLine(JSON.stringify({type:"tool_execution_start",session:"sibling",toolName:"bash",toolCallId:"bash-1"}),0)
      } else if (test.phase === 2) {
        test.mountedOrb = test.orb("nixos")
        test.check(test.mountedOrb !== null, "root missing: " + JSON.stringify(rail.liveSessions))
        test.check(test.mountedOrb.running && test.mountedOrb.visible, "idle parent with active descendants must show a collapsed orb")
        test.check(test.mountedOrb.combined && test.mountedOrb.activityColors.length === 2, "orb must include both active descendants")
        test.check(test.mountedOrb.activityColors.map(String).indexOf(String(AgentActivity.colorFor("read"))) >= 0 && test.mountedOrb.activityColors.map(String).indexOf(String(AgentActivity.colorFor("bash"))) >= 0, "descendant tool colors lost")
        test.check(!rail.featuredFleetStreaming, "unrelated activity leaked into selected root")
        state.onLine(JSON.stringify({type:"tool_execution_start",session:"grandchild",toolName:"write",toolCallId:"write-1"}),0)
        rail.rosterOverride = true
      } else if (test.phase === 3) {
        test.check(test.orb("nixos") === test.mountedOrb && !test.mountedOrb.running, "expanded parent must keep its own idle state without remounting")
        rail.rosterOverride = false
      } else if (test.phase === 4) {
        test.check(test.orb("nixos") === test.mountedOrb && test.mountedOrb.running, "collapse must restore descendant activity without remounting")
        test.check(test.mountedOrb.activityColors.map(String).indexOf(String(AgentActivity.colorFor("write"))) >= 0, "tool change did not refresh the collapsed fleet colors")
        test.roster("idle", "streaming")
      } else if (test.phase === 5) {
        test.check(test.mountedOrb.running && test.mountedOrb.activityColors.length === 1, "remaining active sibling disappeared")
        test.roster("idle", "idle")
      } else if (test.phase === 6) {
        test.check(!test.mountedOrb.running && test.find(test.mountedOrb.parent,"rootIdleDot").visible, "finished fleet must return to idle")
        test.check(test.orb("unrelated").running, "independent running root lost activity")
        test.roster("idle", "idle", "streaming")
      } else if (test.phase === 7) {
        test.check(test.mountedOrb.running && test.mountedOrb.activityColors.length === 1, "root's own activity lost")
        console.log("PASS: collapsed parent aggregates descendant tool colors, excludes unrelated work, settles idle, and preserves expanded individual state")
        Qt.quit()
      }
      test.phase++
    }
  }
}

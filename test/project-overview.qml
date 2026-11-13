import QtQuick
import Quickshell
import QsLib
import "."

ShellRoot {
  id: test
  property int phase: 0
  AgentdState { id: state; sockPaths: [Quickshell.env("XDG_RUNTIME_DIR") + "/agentd-work.sock"]; function send(message) { return true } }
  FloatingWindow {
    visible: true; implicitWidth: 1000; implicitHeight: 1400
    Dashboard {
      id: dash
      anchors.fill: parent
      model: ({kind:"home", scope:"lovable"})
      focusedSession: "coord"
      sessions: state.sessions.map(s => Object.assign({}, s, {offline:false, status:s.name === "busy" ? "streaming" : "idle"}))
      askFor: sid => { state.askGen; return state.askFor(sid) }
    }
  }
  function receive(message) { state.onLine(JSON.stringify(message), 0) }
  function check(value, message) { if (!value) throw new Error(message) }
  function find(item, name) {
    if (item.objectName === name) return item
    for (var child of item.children || []) { var found = find(child, name); if (found) return found }
    return null
  }
  Timer {
    interval: 150; repeat: true; running: true
    onTriggered: {
      if (test.phase === 0) {
        test.receive({type:"roster",sessions:[
          {name:"coord",project:"demo",cwd:"/p",status:"idle",costUsd:1},
          {name:"asker",project:"demo",parent:"coord",cwd:"/p",status:"idle",costUsd:1},
          {name:"busy",project:"demo",parent:"coord",cwd:"/p",status:"streaming",costUsd:1},
          {name:"fresh",project:"demo",parent:"coord",cwd:"/p",status:"idle",costUsd:0},
          {name:"done-a",project:"demo",parent:"coord",cwd:"/p",status:"idle",costUsd:2},
          {name:"done-b",project:"demo",parent:"coord",cwd:"/p",status:"idle",costUsd:2},
          {name:"other",project:"else",cwd:"/p",status:"idle",costUsd:1},
          {name:"every-42",profile:"lovable-worker",cwd:"/vm/42",status:"idle"}
        ]})
        test.receive({type:"extension_ui_request",session:"asker",method:"confirm",id:"ask-1",title:"Ship it?",message:"May I push?"})
      } else if (test.phase === 2) {
        test.check(dash.showSessions && dash.tabs.length === 0, "project coordinator did not open the project overview")
        test.check(dash.workers.map(s => s.name).join(",") === "asker,busy,fresh,done-a,done-b",
          "project sessions not grouped as needs you, working, ready: " + dash.workers.map(s => s.name).join(","))
        var needs = test.find(dash, "groupHeader:NEEDS YOU"), working = test.find(dash, "groupHeader:WORKING"), ready = test.find(dash, "groupHeader:READY")
        test.check(needs && working && ready && needs.visible && working.visible && ready.visible, "a group header is missing")
        test.check(ready.text === "READY · 2", "ready count wrong: " + ready.text)
        var asker = test.find(dash, "sessionCard:asker"), busy = test.find(dash, "sessionCard:busy"), doneA = test.find(dash, "sessionCard:done-a")
        test.check(asker && busy && doneA, "project cards missing")
        test.check(busy.x === 0 && busy.y >= asker.y + asker.height, "WORKING does not start its own row under NEEDS YOU")
        test.check(doneA.x === 0 && doneA.y > busy.y + busy.height && working.y < busy.y && ready.y < doneA.y, "READY header or row misplaced")
        test.check(!test.find(dash, "sessionCard:other") && !test.find(dash, "sessionCard:every-42") && !test.find(dash, "sessionCard:coord"),
          "sessions outside the project, or the coordinator itself, became cards")
        dash.focusedSession = "every-42"
      } else if (test.phase === 3) {
        test.check(dash.sessionHome && dash.tabs.join(",") === "sessions,tickets", "Lovable home lost its tabs")
        test.check(dash.workers.map(s => s.name).join(",") === "every-42", "Lovable home changed its worker selection")
        test.check(!test.find(dash, "groupHeader:READY") || !test.find(dash, "groupHeader:READY").visible, "Lovable home shows project headers")
        console.log("PASS: project coordinator overview groups its sessions into needs you, working and ready; Lovable home unchanged")
        Qt.quit()
      }
      test.phase++
    }
  }
}

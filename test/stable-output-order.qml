import QtQuick
import Quickshell
import "."

ShellRoot {
  id: test
  property int phase: 0
  property int waits: 0
  property real activityY: -1
  property string activityKey: ""

  AgentdState {
    id: state
    selectedSession: rail.selectedRaw
    function send(message) { return true }
  }

  FloatingWindow {
    visible: true
    width: 720
    height: 800
    Rail {
      id: rail
      anchors.fill: parent
      agentd: state
      scopeMode: "personal"
      instanceName: "stable-output-order-test"
      focused: true
    }
  }

  function check(value, message) { if (!value) throw new Error(message) }
  function event(message) { state.onLine(JSON.stringify(message), 0) }
  function ready(value) {
    if (value) { waits = 0; return true }
    if (++waits > 12) throw new Error("feed did not settle at phase " + phase + ": " + JSON.stringify({feed:state.feedFor("worker"),grouped:rail.groupedFeed}))
    return false
  }
  function checkOrder(stage) {
    check(rail.groupedFeed.length === 3, stage + " did not keep user, activity, and prose as separate rows: " + JSON.stringify(rail.groupedFeed))
    check(rail.groupedFeed[1].items[0].kind === "cmd" && rail.groupedFeed[2].items[0].kind === "text", stage + " projection is not chronological")
    var geometry = rail.feedGeom()
    check(geometry.length === 3 && geometry[1].h > 0 && geometry[2].h > 0, stage + " did not realize both activity and prose cards")
    check(geometry[1].y < geometry[2].y, stage + " placed new prose above prior activity")
    check(Math.abs(geometry[1].y - activityY) < 1, stage + " moved the prior activity card")
  }

  Timer {
    interval: 200
    repeat: true
    running: true
    onTriggered: {
      if (phase === 0) {
        event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"streaming"}]})
      } else if (phase === 1) {
        rail.jumpToSession("worker")
        event({type:"response",command:"get_entries",session:"worker",data:{entries:[]}})
        event({type:"prompt_accepted",session:"worker",message:"Check ordering"})
      } else if (phase === 2) {
        event({type:"tool_execution_start",session:"worker",toolCallId:"read-1",toolName:"read",args:{path:"package.json"}})
      } else if (phase === 3) {
        var geometry = rail.feedGeom()
        if (!ready(rail.groupedFeed.length === 2 && geometry.length === 2)) return
        activityY = geometry[1].y
        activityKey = rail.groupedFeed[1].key
        event({type:"message_start",session:"worker",message:{role:"assistant"}})
        event({type:"message_update",session:"worker",assistantMessageEvent:{type:"text_delta",delta:"Streaming answer stays below"}})
      } else if (phase === 4) {
        if (!ready(rail.groupedFeed.length === 3 && rail.feedGeom().length === 3)) return
        checkOrder("streaming")
        check(rail.groupedFeed[1].key === activityKey, "streaming changed the activity row identity")
        event({type:"message_end",session:"worker",message:{role:"assistant",content:[
          {type:"toolCall",id:"read-1",name:"read",arguments:{path:"package.json"}},
          {type:"text",text:"Streaming answer stays below"}
        ]}})
      } else if (phase === 5) {
        if (!ready(rail.groupedFeed.length === 3 && rail.feedGeom().length === 3)) return
        checkOrder("completion")
        event({type:"response",command:"get_entries",session:"worker",data:{leafId:"a",entries:[
          {type:"message",id:"u",parentId:null,message:{role:"user",content:[{type:"text",text:"Check ordering"}]}},
          {type:"message",id:"a",parentId:"u",message:{role:"assistant",content:[
            {type:"toolCall",id:"read-1",name:"read",arguments:{path:"package.json"}},
            {type:"text",text:"Streaming answer stays below"}
          ]}}
        ]}})
      } else if (phase === 6) {
        if (!ready(rail.groupedFeed.length === 3 && rail.feedGeom().length === 3 && rail.groupedFeed[1].key === "a:0")) return
        checkOrder("history")
        console.log("PASS: prior activity keeps its visible position above streaming, completed, and rebuilt prose")
        Qt.quit()
      }
      phase++
    }
  }
}

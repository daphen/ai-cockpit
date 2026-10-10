import QtQuick
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  readonly property string captureDir: Quickshell.env("COCKPIT_PAINT_DIR")
  property bool capturing: false
  property var restingRows: []
  AgentdState { id: state; selectedSession: rail.selectedRaw; function send(message) { return true } }
  FloatingWindow { visible: true; width: 900; height: 1100
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "feed-paint-test"; focused: false }
  }
  function snapshot(offset, count) {
    var entries = [], parent = null
    for (var i=offset;i<offset+count;i++) {
      var u="u"+i, a="a"+i
      entries.push({id:u,parentId:parent,type:"message",message:{role:"user",content:[{type:"text",text:"User message " + i}]}})
      entries.push({id:a,parentId:u,type:"message",message:{role:"assistant",content:[
        {type:"text",text:"Agent answer " + i + ".\n\nA second paragraph to change the card's height."},
        {type:"toolCall",id:"read"+i,name:"read",arguments:{path:"file"+i+".txt"}}
      ]}})
      parent=a
    }
    state.onLine(JSON.stringify({type:"response",command:"get_entries",session:"worker",data:{entries:entries,leafId:parent}}),0)
  }
  Timer { interval: 180; repeat: true; running: true
    onTriggered: {
      if (test.capturing) return
      if (test.phase===0) {
        state.onLine(JSON.stringify({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle"},{id:"other",name:"other",cwd:"/tmp",status:"idle"}]}),0)
        rail.jumpToSession("worker")
        test.snapshot(0,25)
      } else if (test.phase<12) test.snapshot(test.phase,25)
      else if (test.phase===12) {
        test.restingRows=rail.feedGeom()
        rail.focused=true
        rail.debugNav("esc")
        rail.debugNav("G")
      } else if (test.phase===14) {
        var selected=rail.feedGeom()
        for (var i=0;i<selected.length;i++) {
          if (selected[i].h!==test.restingRows[i].h) throw new Error("Selecting an article changed row "+i+" height from "+test.restingRows[i].h+" to "+selected[i].h)
        }
        rail.focused=false
      } else if (test.phase===15) {
        test.capturing=true
        rail.grabToImage(function(result) {
          if (!result.saveToFile(test.captureDir+"/incremental.png")) throw new Error("could not save incremental frame")
          test.capturing=false
        })
      } else if (test.phase===16) rail.jumpToSession("other")
      else if (test.phase===17) rail.jumpToSession("worker")
      else if (test.phase===22) {
        test.capturing=true
        rail.grabToImage(function(result) {
          if (!result.saveToFile(test.captureDir+"/reset.png")) throw new Error("could not save reset frame")
          console.log("PASS: captured incremental and reset frames; graphics API="+rail.GraphicsInfo.api)
          Qt.quit()
        })
      }
      test.phase++
    }
  }
}

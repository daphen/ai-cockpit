import QtQuick
import QtTest
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  readonly property string report: "Finding: candidate CSS is missing. " + "Evidence from the served stylesheet. ".repeat(30) + "END OF REPORT"
  AgentdState { id: state; selectedSession: rail.selectedRaw; function send(message) { return true } }
  FloatingWindow {
    visible: true; width: 720; height: 1000
    Rail {
      id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "message-presentation-test"; focused: true
      onRequestFocus: forceActiveFocus()
      TestEvent { id: input }
    }
  }
  function check(value, message) { if (!value) throw new Error(message) }
  function find(item, predicate) {
    if (!item || item.visible === false) return null
    if (predicate(item)) return item
    for (var child of item.children || []) { var found = find(child, predicate); if (found) return found }
    return null
  }
  function label(text) { return find(rail, item => item.text === text) }
  function click(item) { check(!!item, "click target missing"); input.mouseClick(item, 5, item.height/2, Qt.LeftButton, Qt.NoModifier, 0) }
  function event(message) { state.onLine(JSON.stringify(message),0) }
  function history() {
    event({type:"response",command:"get_entries",session:"worker",data:{leafId:"a",entries:[
      {type:"message",id:"u",parentId:null,message:{role:"user",content:[{type:"text",text:"⇄ css-map (user-approved)\n"+report}]}},
      {type:"message",id:"a",parentId:"u",message:{role:"assistant",content:[
        {type:"thinking",thinking:"Investigating build graph\nLonger reasoning."},
        {type:"toolCall",id:"read",name:"read",arguments:{path:"package.json"}},
        {type:"text",text:"The CSS rule is missing; the fix is not verified."}
      ]}}
    ]}})
  }
  Timer {
    interval: 200; repeat: true; running: true
    onTriggered: {
      if (test.phase === 0) test.event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"streaming"}]})
      else if (test.phase === 1) {
        rail.jumpToSession("worker")
        test.event({type:"prompt_accepted",session:"worker",message:"⇄ css-map (user-approved)\n"+test.report})
      } else if (test.phase === 2) {
        test.check(test.label("From css-map (user-approved)"), "live handoff mislabeled")
        test.check(!test.label("you"), "handoff attributed to human")
        var preview = test.find(rail, item => item.text && item.text.indexOf("Finding: candidate CSS") === 0)
        test.check(preview && preview.maximumLineCount === 3 && preview.truncated, "missing bounded report preview")
        test.click(test.label("Show full message"))
      } else if (test.phase === 3) {
        test.check(test.label("Hide full message"), "message disclosure did not open")
        test.check(test.find(rail, item => item.text && item.text.indexOf("END OF REPORT") >= 0 && item.maximumLineCount !== 3), "full report unavailable")
        test.history()
      } else if (test.phase === 5) {
        test.check(test.label("From css-map (user-approved)"), "history handoff lost its sender")
        test.check(!test.label("Investigating build graph"), "reasoning still visible by default")
        test.check(test.find(rail, item => item.text && item.text.indexOf("The CSS rule is missing") >= 0), "answer hidden with details")
        test.click(test.find(rail, item => item.text && item.text.indexOf("Details") === 0))
      } else if (test.phase === 6) {
        var thought = test.label("Investigating build graph")
        test.check(thought, "details cannot reveal reasoning without Bash calls")
        var answer = test.find(rail, item => item.text && item.text.indexOf("The CSS rule is missing") >= 0)
        test.check(answer.mapToItem(rail,0,0).y < thought.mapToItem(rail,0,0).y, "reasoning precedes answer")
        rail.cur = rail.rSize + 1; rail.exitInsert(); rail.forceActiveFocus()
        input.keyClick(Qt.Key_Return,Qt.ControlModifier,0)
      } else if (test.phase === 7) {
        test.check(!test.label("Investigating build graph"), "Ctrl+Enter failed to close details")
        test.event({type:"error",session:"worker",error:"Worker report was not delivered"})
      } else if (test.phase === 9) {
        test.check(test.label("Worker report was not delivered"), "delivery error hidden")
        test.event({type:"prompt_accepted",session:"worker",message:"A normal human message"})
      } else if (test.phase === 11) {
        test.check(test.label("you"), "human message attribution changed")
        console.log("PASS: live/history senders, bounded previews, full-message disclosure, result-first details, keyboard toggle, and visible delivery errors")
        Qt.quit()
      }
      test.phase++
    }
  }
}

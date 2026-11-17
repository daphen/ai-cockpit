import QtQuick
import QtTest
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  AgentdState { id: state; selectedSession: rail.selectedRaw; function send(message) { return true } }
  FloatingWindow {
    visible: true; width: 720; height: 1200
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "stream-tools-test"; focused: true }
  }
  function check(value,message) { if (!value) { console.log("Error: " + message); Qt.exit(1); throw new Error(message) } }
  function event(message) { state.onLine(JSON.stringify(Object.assign({session:"worker"},message)),0) }
  function rows(item, out) {
    if (!item || !item.visible) return out
    if (item.cardKey !== undefined && item.activity !== undefined) {
      var a = item.activity
      out.push((a.kind === "edits" ? "edit:" + (a.files || []).map(f => f.id || f.path).join("+") : (a.id || a.tool)) + (item.opacity < 0.99 ? "(fading " + item.opacity.toFixed(2) + ")" : ""))
    }
    for (var c of item.children || []) rows(c, out)
    return out
  }
  property var calls: [
    {id:"t1", name:"bash", args:{command:"make build"}},
    {id:"t2", name:"read", args:{path:"/tmp/a.qml"}},
    {id:"t3", name:"bash", args:{command:"grep -n foo a.qml"}},
    {id:"t4", name:"edit", args:{path:"/tmp/a.qml", edits:[{oldText:"a", newText:"b"}]}},
    {id:"t5", name:"bash", args:{command:"make test"}}
  ]
  property var shown: []
  Timer {
    interval: 150; repeat: true; running: true
    onTriggered: {
      var p = phase++
      if (p === 0) {
        event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"streaming"}]})
        rail.jumpToSession("worker")
        event({type:"response",command:"get_entries",data:{leafId:"u1",entries:[{type:"message",id:"u1",parentId:null,message:{role:"user",content:[{type:"text",text:"go"}]}}]}})
        event({type:"agent_start"})
      } else if (p >= 3 && p < 3 + 2 * calls.length) {
        var c = calls[(p - 3) >> 1]
        if ((p - 3) % 2 === 0) {
          event({type:"message_start", message:{role:"assistant",content:[]}})
          event({type:"message_end", message:{role:"assistant",model:"m",content:[{type:"toolCall",id:c.id,name:c.name,arguments:c.args}]}})
          event({type:"tool_execution_start", toolCallId:c.id, toolName:c.name, args:c.args})
        } else event({type:"tool_execution_end", toolCallId:c.id, toolName:c.name, result:{content:[{type:"text",text:"ok"}], details: c.name === "edit" ? {diff:"+1 b\n-1 a"} : undefined}})
        gui.wait(60)
        var now = rows(rail, []).map(r => r.split("(")[0])
        var step = "after " + ((p - 3) % 2 ? "end " : "start ") + c.id
        for (var was of shown) check(now.indexOf(was) >= 0, step + ": the " + was + " row vanished after it had appeared; rows " + JSON.stringify(now))
        check(now.indexOf("t2") < 0 && now.indexOf("t3") < 0, step + ": a read or grep got its own row " + JSON.stringify(now))
        shown = now
      } else if (p === 4 + 2 * calls.length) {
        check(shown.join() === "t1,edit:t4,t5", "the card should end with the build, the edit and the test run, got " + shown.join())
        console.log("PASS: streamed tool rows never vanish once shown, and reads stay behind Work details")
        Qt.quit()
      }
    }
  }
  TestCase { id: gui; when: false }
}

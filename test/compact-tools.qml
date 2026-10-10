import QtQuick
import QtTest
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  AgentdState { id: state; selectedSession: rail.selectedRaw; function send(message) { return true } }
  FloatingWindow {
    visible: true; width: 720; height: 1000
    Rail {
      id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "compact-tools-test"; focused: true
      onRequestFocus: forceActiveFocus()
      TestEvent { id: input }
    }
  }
  TestCase { id: gui; when: false }
  function check(value,message) { if (!value) throw new Error(message) }
  function find(item,predicate) {
    if (!item || !item.visible) return null
    if (predicate(item)) return item
    for (var child of item.children || []) { var match = find(child,predicate); if (match) return match }
    return null
  }
  function label(text) { return find(rail,item => item.text === text) }
  function details() { return find(rail,item => String(item.objectName || "").indexOf("work-details:") === 0) }
  function click(item) { check(item,"missing click target"); gui.wait(30); input.mouseClick(item,5,item.height/2,Qt.LeftButton,Qt.NoModifier,0) }
  function event(message) { state.onLine(JSON.stringify(Object.assign({session:"worker"},message)),0) }
  Timer {
    interval: 220; repeat: true; running: true
    onTriggered: {
      if (phase === 0) {
        event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle"}]})
        rail.jumpToSession("worker")
        event({type:"response",command:"get_entries",data:{leafId:"r2",entries:[
          {type:"message",id:"a",parentId:null,message:{role:"assistant",model:"gpt-6.1-sol",content:[
            {type:"text",text:"The answer stays readable."},
            {type:"toolCall",id:"read",name:"read",arguments:{path:"/tmp/source.qml"}},
            {type:"toolCall",id:"bash",name:"bash",arguments:{command:"check fixture"}}
          ]}},
          {type:"message",id:"r1",parentId:"a",message:{role:"toolResult",toolCallId:"read",toolName:"read",content:[{type:"text",text:"SOURCE_ONLY_NEOVIM"}]}},
          {type:"message",id:"r2",parentId:"r1",message:{role:"toolResult",toolCallId:"bash",toolName:"bash",isError:true,content:[{type:"text",text:"Error: Fixture failure\nCommand exited with code 1"}]}}
        ]}})
      } else if (phase === 1) {
        check(find(rail,item => String(item.text || "").startsWith("The answer stays readable.")) && label("Work details · 2 tools") && label("1 failed"),"reply or compact failure summary missing")
        check(!label("read source.qml") && !label("check fixture  — failed") && !find(rail,item => String(item.objectName || "").indexOf("tool-preview:") === 0),"completed commands/errors still dominate the default view")
        click(details())
      } else if (phase === 2) {
        var command = label("check fixture  — failed"), read = label("read source.qml")
        check(command && read,"tool disclosure lost rows")
        var heading = details(), icon = find(read.parent,item => item.name === "file-content")
        check(icon && Math.abs(icon.mapToItem(rail,0,0).x-heading.mapToItem(rail,0,0).x-24) < 1,"tool hierarchy lacks indentation")
        check(command.font.pixelSize < find(rail,item => String(item.text || "").startsWith("The answer stays readable.")).font.pixelSize,"command type competes with the reply")
        check(!find(rail,item => String(item.text || "").includes("SOURCE_ONLY_NEOVIM")),"read source leaked into the transcript")
        click(command)
      } else if (phase === 3) {
        check(find(rail,item => item.objectName === "tool-output:bash" && item.text.includes("Fixture failure")),"full failure is inaccessible")
        click(details())
      } else if (phase === 4) {
        check(!label("check fixture  — failed"),"closing work details left diagnostics exposed")
        event({type:"tool_execution_start",toolCallId:"live",toolName:"bash",args:{command:"current command"}})
      } else if (phase === 5) {
        check(find(rail,item => String(item.text || "").startsWith("current command")),"current tool hidden by compact history")
        check(!label("check fixture  — failed"),"running tool reopened old failures")
        event({type:"tool_execution_end",toolCallId:"live",toolName:"bash",isError:false,result:{content:[{type:"text",text:"Done"}]}})
      } else if (phase === 6) {
        check(!label("current command"),"completed live command did not compact")
        console.log("PASS: compact history/failure counts, subordinate tool typography/indentation, full diagnostics, hidden source, visible current tool and automatic completion compaction")
        Qt.quit()
      }
      phase++
    }
  }
}

import QtQuick
import QtTest
import Quickshell
import QsLib
import "."
ShellRoot {
  id: test
  property int phase: 0
  AgentdState { id: state; selectedSession: rail.selectedRaw; function send(message) { return true } }
  FloatingWindow {
    visible: true; width: 720; height: 1400
    Rail {
      id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "tool-presentation-test"; focused: true
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
  function named(prefix) { return find(rail,item => String(item.objectName || "").indexOf(prefix) === 0) }
  function starting(text) { return find(rail,item => String(item.text || "").indexOf(text) === 0) }
  function details() { return named("work-details:") }
  function click(item) { check(item,"missing click target"); gui.wait(30); input.mouseClick(item,5,item.height/2,Qt.LeftButton,Qt.NoModifier,0) }
  function event(message) { state.onLine(JSON.stringify(Object.assign({session:"worker"},message)),0) }
  readonly property string longOutput: Array.from({length: 30}, (_, row) => "line " + (row + 1)).join("\n")
  Timer {
    interval: 220; repeat: true; running: true
    onTriggered: {
      if (phase === 0) {
        event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle"}]})
        rail.jumpToSession("worker")
        event({type:"response",command:"get_entries",data:{leafId:"r3",entries:[
          {type:"message",id:"a",parentId:null,message:{role:"assistant",model:"gpt-6.1-sol",content:[
            {type:"text",text:"Tools follow."},
            {type:"toolCall",id:"read",name:"read",arguments:{path:"/tmp/view.qml",offset:10,limit:20}},
            {type:"toolCall",id:"bash",name:"bash",arguments:{command:"seq 30"}},
            {type:"toolCall",id:"edit",name:"edit",arguments:{path:"/tmp/view.qml",edits:[{oldText:"a",newText:"b"}]}}
          ]}},
          {type:"message",id:"r1",parentId:"a",message:{role:"toolResult",toolCallId:"read",toolName:"read",content:[{type:"text",text:"SOURCE_ONLY_NEOVIM"}]}},
          {type:"message",id:"r2",parentId:"r1",message:{role:"toolResult",toolCallId:"bash",toolName:"bash",content:[{type:"text",text:longOutput}]}},
          {type:"message",id:"r3",parentId:"r2",message:{role:"toolResult",toolCallId:"edit",toolName:"edit",content:[{type:"text",text:"Edited"}],
            details:{diff:" 11   Item {\n-12     property int count: 1\n+12     property int count: 2\n 13   }"}}}
        ]}})
      } else if (phase === 1) {
        check(starting("seq 30") && !starting("read view.qml"),"default view should show commands and hide reads")
        click(details())
      } else if (phase === 2) {
        check(starting("read view.qml:10-29"),"read row lacks its line range")
        check(!find(rail,item => String(item.text || "").includes("SOURCE_ONLY_NEOVIM")),"read source leaked into the transcript")
        click(starting("seq 30"))
      } else if (phase === 3) {
        var output = named("tool-output:bash")
        check(output && output.text.indexOf("line 21") === 0 && output.text.indexOf("line 20\n") < 0,"long output is not capped to its last lines")
        click(named("tool-earlier:bash"))
      } else if (phase === 4) {
        check(named("tool-output:bash").text.indexOf("line 1\n") === 0,"show all did not reveal the full output")
        var toggle = named("edit-diff-toggle:/tmp/view.qml")
        check(toggle,"edit row offers no diff")
        gui.wait(30); input.mouseClick(toggle,5,toggle.height/2,Qt.LeftButton,Qt.NoModifier,0)
      } else if (phase === 5) {
        var panel = named("edit-diff:/tmp/view.qml")
        check(panel,"diff panel did not open")
        check(find(panel,item => String(item.text || "").includes("count:") && String(item.text).includes("<font color=")),"diff lines are not highlighted")
        event({type:"auto_retry_start",attempt:1,maxAttempts:3,errorMessage:"overloaded"})
      } else if (phase === 6) {
        check(starting("↻ retrying (1/3)"),"retry notice missing")
        event({type:"auto_retry_end",success:true})
      } else if (phase === 7) {
        check(!starting("↻ retrying"),"retry notice outlived a successful retry")
        event({type:"message_update",assistantMessageEvent:{type:"toolcall_delta",contentIndex:0,
          partial:{content:[{type:"toolCall",name:"grep",arguments:{pattern:"needle",path:"/tmp/src"}}]}}})
      } else if (phase === 8) {
        check(starting("grep \"needle\" in /tmp/src …"),"tool call arguments do not stream")
        event({type:"tool_execution_start",toolCallId:"live",toolName:"grep",args:{pattern:"needle",path:"/tmp/src"}})
      } else if (phase === 9) {
        check(!starting("grep \"needle\" in /tmp/src …") && starting("grep \"needle\" in /tmp/src"),"streamed preview was not replaced by the real call")
        event({type:"queue_update",steering:["also check the footer"],followUp:[]})
      } else if (phase === 10) {
        click(starting("queued · 1 steer"))
      } else if (phase === 11) {
        check(find(rail,item => String(item.text || "").includes("steer: also check the footer")),"queued message text is not expandable")
        event({type:"response",command:"get_entries",data:{leafId:"f2",entries:[
          {type:"message",id:"b",parentId:null,message:{role:"assistant",model:"gpt-6.1-sol",content:[
            {type:"text",text:"Retried the edit."},
            {type:"toolCall",id:"try1",name:"edit",arguments:{path:"/tmp/retry.qml",edits:[{oldText:"a",newText:"b"}]}},
            {type:"toolCall",id:"try2",name:"edit",arguments:{path:"/tmp/retry.qml",edits:[{oldText:"a",newText:"b"}]}}
          ]}},
          {type:"message",id:"f1",parentId:"b",message:{role:"toolResult",toolCallId:"try1",toolName:"edit",isError:true,content:[{type:"text",text:"Could not find edits[0]"}]}},
          {type:"message",id:"f2",parentId:"f1",message:{role:"toolResult",toolCallId:"try2",toolName:"edit",content:[{type:"text",text:"Edited"}]}}
        ]}})
      } else if (phase === 12) {
        var count = find(rail,item => item.text === "1 failed")
        check(count && !Qt.colorEqual(count.color,Theme.red),"a retried failure is still painted red")
        check(!named("tool-preview:try1"),"a retried failure still shows its error line")
        event({type:"response",command:"get_entries",data:{leafId:"g1",entries:[
          {type:"message",id:"c",parentId:null,message:{role:"assistant",model:"gpt-6.1-sol",content:[
            {type:"text",text:"Gave up on the edit."},
            {type:"toolCall",id:"stuck",name:"edit",arguments:{path:"/tmp/stuck.qml",edits:[{oldText:"a",newText:"b"}]}}
          ]}},
          {type:"message",id:"g1",parentId:"c",message:{role:"toolResult",toolCallId:"stuck",toolName:"edit",isError:true,content:[{type:"text",text:"Permission denied"}]}}
        ]}})
      } else if (phase === 13) {
        var red = find(rail,item => item.text === "1 failed")
        check(red && Qt.colorEqual(red.color,Theme.red) && named("tool-preview:stuck"),"an unresolved failure is not red with its error line")
        console.log("PASS: read ranges, capped output with show all, highlighted inline diffs, retry notice clears, streamed tool arguments, expandable queue, useful default view, quiet retried failures")
        Qt.quit()
      }
      phase++
    }
  }
}

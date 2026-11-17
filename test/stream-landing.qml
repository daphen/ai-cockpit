import QtQuick
import QtTest
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  property string opened: ""
  AgentdState { id: state; selectedSession: rail.selectedRaw; function send(message) { return true } }
  FloatingWindow {
    visible: true; width: 720; height: 1200
    Rail {
      id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "stream-landing-test"; focused: true
      onRequestFocus: forceActiveFocus()
      function openFileRef(path) { test.opened = String(path) }
      TestEvent { id: input }
    }
  }
  TestCase { id: gui; when: false }
  function check(value,message) { if (!value) { console.log("Error: " + message); Qt.exit(1); throw new Error(message) } }
  function find(item,predicate) {
    if (!item || !item.visible) return null
    if (predicate(item)) return item
    for (var child of item.children || []) { var match = find(child,predicate); if (match) return match }
    return null
  }
  function named(prefix) { return find(rail,item => String(item.objectName || "").indexOf(prefix) === 0) }
  function key(k) { gui.wait(20); input.keyClick(k,Qt.NoModifier,0) }
  function event(message) { state.onLine(JSON.stringify(Object.assign({session:"worker"},message)),0) }
  property int before: 0
  function update(ev, extra) { event(Object.assign({type:"message_update", message:{role:"assistant", model:"m"}, assistantMessageEvent: ev}, extra || {})) }
  readonly property var a1: ({role:"assistant", model:"m", content:[{type:"thinking", thinking:"**Looking at the file** I should list it."},{type:"text", text:longText},{type:"toolCall", id:"t1", name:"bash", arguments:{command:"ls"}}]})
  readonly property var a2: ({role:"assistant", model:"m", content:[{type:"text", text:"All done, the file is fine."}]})
  function transcript(done) {
    var e = [{type:"message",id:"u1",parentId:null,message:{role:"user",content:[{type:"text",text:"look at it"}]}},
             {type:"message",id:"x1",parentId:"u1",message:a1},
             {type:"message",id:"r1",parentId:"x1",message:{role:"toolResult",toolCallId:"t1",toolName:"bash",content:[{type:"text",text:"a\nb"}]}}]
    if (done) e.push({type:"message",id:"x2",parentId:"r1",message:a2})
    return {type:"response",command:"get_entries",data:{leafId: done ? "x2" : "r1", entries:e}}
  }
  readonly property string longText: "Checking the file first. " + Array.from({length: 12}, (_, n) => "This sentence " + n + " explains a little more.").join(" ")
  function cards(item, out) {
    if (!item) return out
    if (item.waitsForProse !== undefined && item.turn !== undefined) out.push(item)
    for (var c of item.children || []) cards(c, out)
    return out
  }
  function toolCard() { return cards(rail, []).find(c => !c.isUser && rail.turnProse(c.turn.items).length === 0 && rail.activityEntries(c.turn.items).length > 0) }
  Timer {
    interval: 120; repeat: true; running: true
    onTriggered: {
      var p = phase++
      if (p === 0) {
        event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle"}]})
        rail.jumpToSession("worker")
        event({type:"response",command:"get_entries",data:{leafId:"u1",entries:[{type:"message",id:"u1",parentId:null,message:{role:"user",content:[{type:"text",text:"look at it"}]}}]}})
      } else if (p === 4) {
        event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"streaming"}]})
        event({type:"agent_start"}); event({type:"message_start", message:{role:"assistant",content:[]}})
        update({type:"thinking_start", contentIndex:0})
        update({type:"thinking_delta", contentIndex:0, delta:"**Looking at the file** I should list it."})
      } else if (p === 41) {
      } else if (p === 5) {
        update({type:"text_start", contentIndex:1})
        update({type:"text_delta", contentIndex:1, delta:longText})
        update({type:"toolcall_start", contentIndex:2, partial:{content:[{},{},{type:"toolCall",name:"bash",arguments:{command:"ls"}}]}})
      } else if (p === 6) {
        var held = toolCard()
        check(held && rail.proseTyping > 0 && held.opacity === 0, "the tool card should wait, unseen, while the reply above it is still typing (typing=" + rail.proseTyping + ", opacity=" + (held ? held.opacity : "none") + ")")
        event({type:"message_end", message:a1})
        event({type:"tool_execution_start", toolCallId:"t1", toolName:"bash", args:{command:"ls"}})
      } else if (p === 7) {
        event({type:"tool_execution_end", toolCallId:"t1", toolName:"bash", result:{content:[{type:"text",text:"a\nb"}]}})
        event({type:"message_start", message:{role:"assistant",content:[]}})
        update({type:"text_start", contentIndex:0})
        update({type:"text_delta", contentIndex:0, delta:"All done, the file is fine."})
      } else if (p === 8) {
        event({type:"message_end", message:a2})
        event({type:"agent_end"})
        event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle"}]})
      } else if (p === 12) {
        check(rail.proseTyping === 0 && toolCard() && toolCard().opacity === 1, "once the reply has typed out, the tool card should be shown (typing=" + rail.proseTyping + ")")
        before = rail.probeCardCreates
        event(transcript(true))
      } else if (p === 16) {
        var recreated = rail.probeCardCreates - before
        check(recreated === 0, "landing the transcript recreated " + recreated + " already-shown cards, replaying their fade-in")
        console.log("PASS: a tool card waits for the reply above it to finish typing, and landing the transcript recreates no card")
        Qt.quit()
      }
    }
  }
}
